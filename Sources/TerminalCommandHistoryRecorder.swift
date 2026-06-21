import CmuxAgentChat
import CmuxTerminal
import Foundation
import os

/// One persisted command-history entry for a terminal tab.
struct TerminalCommandHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    /// Stable ordinal within the tab's history file (monotonic across reopens).
    let id: Int
    /// The command line the user ran (OSC 133 `B`…`C` text), trimmed.
    let command: String
    /// The command's exit code, or `nil` if it never reported one.
    let exitCode: Int?
    /// When the command finished, as seconds since 1970.
    let recordedAt: TimeInterval

    private enum CodingKeys: String, CodingKey {
        case id
        case command
        case exitCode = "exit_code"
        case recordedAt = "recorded_at"
    }
}

/// Records each terminal tab's executed commands — parsed from the OSC 133
/// shell-integration marks already present in the live PTY stream — into a
/// per-tab side file (`<AppSupport>/cmux/shell-history/_commands/<surface>.commands.json`)
/// so the command-history view can show them again after the tab reopens.
///
/// **Hot-path discipline (CLAUDE.md typing-latency rule):** ``append(surfaceID:bytes:)``
/// runs on the Ghostty IO read thread for *every* surface. It does an O(1)
/// enabled check and, only when recording is on, a single byte copy plus a
/// non-blocking enqueue onto a private serial queue. All UTF-8 decoding, OSC 133
/// parsing, and disk I/O happen on that queue — never on the IO thread or the
/// main thread.
///
/// `@unchecked Sendable`: every mutable field except the lock-guarded enabled
/// flag is touched only on ``queue`` (serial), so cross-thread access is
/// serialized by construction.
final class TerminalCommandHistoryRecorder: @unchecked Sendable {
    nonisolated static let shared = TerminalCommandHistoryRecorder()

    /// Max entries kept per tab; the oldest are dropped past this.
    private static let maxEntriesPerSurface = 1000

    /// Hot-path gate, mirrored from `session.persistShellHistory`. Behind an
    /// unfair lock so the IO read thread reads it cheaply and race-free.
    private let enabled = OSAllocatedUnfairLock(initialState: false)

    private struct SurfaceState {
        var parser = OSC133CommandParser()
        var entries: [TerminalCommandHistoryEntry] = []
        var nextID = 0
        var loaded = false
    }

    /// Touched only on ``queue`` (or synchronously in tests via ``ingest``).
    private var statesBySurfaceID: [UUID: SurfaceState] = [:]
    private let queue = DispatchQueue(label: "dev.cmux.command-history.recorder", qos: .utility)
    private let fileManager = FileManager.default
    private let clock: @Sendable () -> TimeInterval
    /// Overridable Application Support root (tests point this at a temp dir).
    private let appSupportDirectory: URL?

    nonisolated init(
        clock: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 },
        appSupportDirectory: URL? = nil
    ) {
        self.clock = clock
        self.appSupportDirectory = appSupportDirectory
    }

    /// Turns recording on/off from `session.persistShellHistory`.
    func setEnabled(_ value: Bool) {
        enabled.withLock { $0 = value }
    }

    private var isEnabled: Bool { enabled.withLock { $0 } }

    /// IO-thread entry point from the PTY tee trampoline. O(1) when disabled.
    nonisolated func append(surfaceID: UUID, bytes: UnsafeBufferPointer<UInt8>) {
        guard isEnabled else { return }
        guard let base = bytes.baseAddress, bytes.count > 0 else { return }
        let copy = Data(bytes: base, count: bytes.count)
        queue.async { [weak self] in
            guard let self else { return }
            self.ingest(surfaceID: surfaceID, text: String(decoding: copy, as: UTF8.self))
        }
    }

    /// Flushes and forgets a surface when it closes.
    func dropSurface(surfaceID: UUID) {
        queue.async { [weak self] in
            self?.statesBySurfaceID.removeValue(forKey: surfaceID)
        }
    }

    // MARK: - Core (serial-queue confined; called synchronously in tests)

    func ingest(surfaceID: UUID, text: String) {
        var state = statesBySurfaceID[surfaceID] ?? SurfaceState()
        if !state.loaded {
            let existing = Self.load(
                surfaceID: surfaceID,
                appSupportDirectory: appSupportDirectory,
                fileManager: fileManager
            )
            state.entries = existing
            state.nextID = (existing.map(\.id).max() ?? -1) + 1
            state.loaded = true
        }

        state.parser.consume(text)
        var changed = false
        for block in state.parser.takeCompletedBlocks() {
            let command = block.command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty else { continue }
            state.entries.append(TerminalCommandHistoryEntry(
                id: state.nextID,
                command: command,
                exitCode: block.exitCode,
                recordedAt: clock()
            ))
            state.nextID += 1
            changed = true
        }

        if changed {
            if state.entries.count > Self.maxEntriesPerSurface {
                state.entries.removeFirst(state.entries.count - Self.maxEntriesPerSurface)
            }
            Self.persist(
                surfaceID: surfaceID,
                entries: state.entries,
                appSupportDirectory: appSupportDirectory,
                fileManager: fileManager
            )
        }
        statesBySurfaceID[surfaceID] = state
    }

    // MARK: - File IO (shared with the view)

    /// Loads a tab's persisted command history, oldest first. Returns `[]` when
    /// the tab has no history yet.
    static func load(
        surfaceID: UUID,
        appSupportDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> [TerminalCommandHistoryEntry] {
        guard
            let url = ShellHistoryLocator.commandsFileURL(
                surfaceID: surfaceID,
                appSupportDirectory: appSupportDirectory,
                fileManager: fileManager
            ),
            let data = try? Data(contentsOf: url),
            let entries = try? JSONDecoder().decode([TerminalCommandHistoryEntry].self, from: data)
        else { return [] }
        return entries
    }

    static func persist(
        surfaceID: UUID,
        entries: [TerminalCommandHistoryEntry],
        appSupportDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        guard let url = ShellHistoryLocator.commandsFileURL(
            surfaceID: surfaceID,
            appSupportDirectory: appSupportDirectory,
            fileManager: fileManager
        ) else { return }
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let data = try JSONEncoder().encode(entries)
            try data.write(to: url, options: .atomic)
        } catch {
            // Best-effort: a failed history write must never disrupt the terminal.
        }
    }
}
