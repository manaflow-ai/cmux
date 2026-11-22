import AppKit
import CmuxNextCompat
import CmuxNextComputerUse
import CmuxNextRemoteView
import Foundation
import os

/// One stdout line of `cmux-screen-sharing __shortcut-tap` (cmux-tui/crates/cmux-rd-host
/// src/shortcut_tap.rs): `{"ready":true}`, `{"error":"..."}`, or a key the helper's tap took.
nonisolated struct MacScreenShortcutTapLine: Decodable, Equatable, Sendable {
    var ready: Bool?
    var error: String?
    var keyCode: UInt16?
    var modifiers: UInt64?
    var down: Bool?
    var isRepeat: Bool?

    enum CodingKeys: String, CodingKey {
        case ready, error, modifiers, down
        case keyCode = "key_code"
        case isRepeat = "repeat"
    }

    /// The key the tap took (its modifiers are NSEvent's flag bits), or nil for any other line.
    var key: RemoteTapKey? {
        guard let keyCode, let down else { return nil }
        return RemoteTapKey(keyCode: keyCode, modifiers: NSEvent.ModifierFlags(rawValue: UInt(modifiers ?? 0)),
                            down: down, isRepeat: isRepeat ?? false)
    }
}

/// Splits the tap's stdout into its lines; an unknown line (a newer helper's) reads as an empty one.
nonisolated struct MacScreenShortcutTapLines: Sendable {
    private var pending = Data()

    mutating func push(_ data: Data) -> [MacScreenShortcutTapLine] {
        pending.append(data)
        var lines: [MacScreenShortcutTapLine] = []
        while let end = pending.firstIndex(of: UInt8(ascii: "\n")) {
            let line = pending[pending.startIndex..<end]
            pending.removeSubrange(pending.startIndex...end)
            guard !line.isEmpty else { continue }
            lines.append((try? JSONDecoder().decode(MacScreenShortcutTapLine.self, from: Data(line))) ?? MacScreenShortcutTapLine())
        }
        return lines
    }
}

/// The app's one stdin line to the tap: whether a remote screen has the keyboard now, and the
/// viewer's release chord (never taken).
nonisolated struct MacScreenShortcutTapControl: Encodable, Equatable, Sendable {
    nonisolated struct Chord: Encodable, Equatable, Sendable {
        var keyCode: UInt16
        var modifiers: UInt64

        enum CodingKeys: String, CodingKey {
            case keyCode = "key_code"
            case modifiers
        }

        init(_ chord: RemoteReleaseChord) {
            keyCode = chord.keyCode
            modifiers = UInt64(chord.modifiers.rawValue)
        }
    }

    var hold: Bool
    var release: Chord?

    static let letGo = MacScreenShortcutTapControl(hold: false, release: nil)

    static func hold(release: RemoteReleaseChord) -> Self {
        MacScreenShortcutTapControl(hold: true, release: Chord(release))
    }

    var line: Data {
        var data = (try? JSONEncoder().encode(self)) ?? Data()
        data.append(UInt8(ascii: "\n"))
        return data
    }
}

/// One `cmux-screen-sharing __shortcut-tap` process: the "Send System Shortcuts to the Remote
/// Mac" session event tap, run in the Screen Sharing helper (``MacScreenHelper``) so macOS checks
/// the helper's Accessibility, never this app's, and a grant never relaunches cmux. The helper
/// decides in its own tap callback which keys it takes (the system list, never the release
/// chord) while this app says it holds; each taken key arrives on ``onKey`` in order, on the main
/// actor. ``stop()`` closes its stdin, which ends it.
final class MacScreenShortcutTap {
    /// The helper's hidden mode word (cmux-rd-host `shortcut_tap::MODE`).
    static let mode = "__shortcut-tap"

    /// A key the helper's tap took from macOS: send it to the other Mac.
    var onKey: (RemoteTapKey) -> Void = { _ in }
    /// The process ended by itself: nil when it ended cleanly, else why (no Accessibility).
    var onEnd: (String?) -> Void = { _ in }
    private var control = MacScreenShortcutTapControl.letGo
    private var stdin: FileHandle?
    /// The stdout and stderr pipes, kept for the process's life (a released `Pipe` closes its
    /// read end under its handler).
    private var pipes: [Pipe] = []
    private var stopped = false
    private let writes = DispatchQueue(label: "com.cmuxterm.mac-screen.shortcut-tap-stdin", qos: .userInitiated)
    private nonisolated static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "mac-screen-shortcut-tap")

    /// Started and not stopped.
    var isRunning: Bool { stdin != nil }

    /// Starts the process `spawn` launches on these stdin, stdout and stderr pipes (the helper
    /// with ``mode``; tests pass a shell) and sends it the current control line.
    func start(_ spawn: (_ stdin: Pipe, _ stdout: Pipe, _ stderr: Pipe) throws -> pid_t) throws {
        guard !stopped, stdin == nil else { return }
        let input = Pipe(), stdout = Pipe(), stderr = Pipe()
        let lines = Self.follow(stdout: stdout, stderr: stderr)
        let pid: pid_t
        do { pid = try spawn(input, stdout, stderr) } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            throw error
        }
        SignedHelperLaunch.reap(pid)
        stdin = input.fileHandleForWriting
        pipes = [stdout, stderr]
        write(control)
        // task-owner: reads this one process's lines until its end of file (stop() or its exit)
        Task { [weak self] in
            var reason: String?
            for await line in lines {
                if let error = line.error { reason = error }
                if let key = line.key { self?.onKey(key) }
            }
            self?.ended(reason)
        }
    }

    /// Tells the tap whether to hold (written only when it changed).
    func send(_ next: MacScreenShortcutTapControl) {
        guard next != control else { return }
        control = next
        write(next)
    }

    /// Ends the process: its stdin closes, it reads end of file and exits. No ``onEnd`` follows.
    func stop() {
        stopped = true
        guard let handle = stdin else { return }
        stdin = nil
        writes.async { try? handle.close() }
    }

    private func write(_ control: MacScreenShortcutTapControl) {
        guard let handle = stdin else { return }
        let line = control.line
        writes.async { try? handle.write(contentsOf: line) }
    }

    private func ended(_ reason: String?) {
        let wasStopped = stopped
        stop()
        pipes = []
        if !wasStopped { onEnd(reason) }
    }

    /// The process's stdout as lines (finished at its end of file), and its stderr to the log.
    private nonisolated static func follow(stdout: Pipe, stderr: Pipe) -> AsyncStream<MacScreenShortcutTapLine> {
        let (lines, continuation) = AsyncStream.makeStream(of: MacScreenShortcutTapLine.self, bufferingPolicy: .bufferingNewest(256))
        let buffer = Mutex(MacScreenShortcutTapLines())
        stdout.fileHandleForReading.readabilityHandler = { handle in
            // concurrency-allow: readabilityHandler runs on Foundation's pipe queue, never main; data is ready.
            let data = handle.blockingAvailableData()
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                continuation.finish()
                return
            }
            for line in buffer.withLock({ $0.push(data) }) { continuation.yield(line) }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            // concurrency-allow: readabilityHandler runs on Foundation's pipe queue, never main; data is ready.
            let data = handle.blockingAvailableData()
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            logger.info("shortcut tap: \(String(decoding: data, as: UTF8.self), privacy: .public)")
        }
        return lines
    }
}
