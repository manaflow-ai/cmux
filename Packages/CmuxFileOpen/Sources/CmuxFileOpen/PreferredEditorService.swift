public import Foundation
public import CmuxSettings
public import CmuxTestSupport
import OSLog

nonisolated private let preferredEditorLogger = Logger(subsystem: "com.cmuxterm.app", category: "PreferredEditor")

/// Opens files in the user's preferred editor, falling back to the system
/// default handler — the launch path lifted from the legacy
/// `PreferredEditorSettings.open`.
///
/// Behavior, kept faithful to the legacy namespace:
/// 1. When a UI-test capture file is configured under
///    `CMUX_UI_TEST_CAPTURE_OPEN_PATH`, the open is recorded there and
///    intercepted (no process or system open).
/// 2. With no configured editor command, the file opens with the system
///    default handler.
/// 3. Otherwise `/bin/sh -c "<command> '<path>'"` is spawned with silenced
///    stdio and a GUI-safe `PATH`; a launch failure or a nonzero exit
///    (e.g. command-not-found exiting 127) falls back to the system default
///    handler.
///
/// Isolation: `@MainActor`, because every caller is a main-thread UI flow
/// and the legacy code spawned the editor process synchronously on the
/// calling (main) thread; co-locating keeps the spawn timing identical.
/// Exit status is observed via `Process.terminationHandler` (replacing the
/// legacy `DispatchQueue.global` + `waitUntilExit` hop); the handler hops
/// back to the main actor for the fallback open, matching the legacy
/// `DispatchQueue.main.async` fallback.
@MainActor
public struct PreferredEditorService: FileOpening {
    private let editor: any PreferredEditorReading
    private let capture: any TestCaptureWriting
    private let systemOpener: any SystemFileOpening

    /// Creates a service with explicit collaborators (tests pass fakes).
    ///
    /// - Parameters:
    ///   - editor: Source of the configured editor command.
    ///   - capture: UI-test capture seam consulted before any real open.
    ///   - systemOpener: Fallback opener for the no-command and
    ///     failed-command paths.
    public init(
        editor: any PreferredEditorReading,
        capture: any TestCaptureWriting,
        systemOpener: any SystemFileOpening
    ) {
        self.editor = editor
        self.capture = capture
        self.systemOpener = systemOpener
    }

    /// Creates the production service: editor command from `defaults`,
    /// capture from the process environment, fallback through `NSWorkspace`.
    public init(defaults: UserDefaults) {
        self.init(
            editor: PreferredEditorSettingsStore(defaults: defaults),
            capture: UITestCaptureSink(),
            systemOpener: NSWorkspaceFileOpener()
        )
    }

    public func open(_ url: URL) {
        let path = url.path(percentEncoded: false)
        if capture.appendLineIfConfigured(
            envKey: "CMUX_UI_TEST_CAPTURE_OPEN_PATH",
            line: path
        ) {
            return
        }

        guard let command = editor.resolvedCommand else {
            systemOpener.openWithSystemDefault(url)
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "\(command) \(path.posixShellSingleQuoted)"]
        process.environment = Self.launchEnvironment()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let systemOpener = self.systemOpener
        let commandName = command.preferredEditorPublicCommandName
        process.terminationHandler = { @Sendable process in
            // Fall back when the command fails (e.g. command not found exits
            // 127 but /bin/sh itself launched fine).
            guard process.terminationStatus != 0 else { return }
            preferredEditorLogger.error(
                "preferred editor command \(commandName, privacy: .public) exited \(process.terminationStatus, privacy: .public) for \(path, privacy: .private); falling back to the OS default handler"
            )
            Task { @MainActor in
                systemOpener.openWithSystemDefault(url)
            }
        }

        do {
            try process.run()
        } catch {
            preferredEditorLogger.error(
                "failed to launch preferred editor command \(commandName, privacy: .public): \(error.localizedDescription, privacy: .public); falling back to the OS default handler"
            )
            systemOpener.openWithSystemDefault(url)
        }
    }

    /// Returns the environment used for spawned editor processes.
    ///
    /// GUI apps inherit a minimal `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`)
    /// that lacks the directories where editor CLIs are typically installed,
    /// so a bare command such as `code` exits 127 even though the same command
    /// works in a terminal (#5817). Append the standard CLI directories when
    /// missing; inherited entries keep precedence.
    static func launchEnvironment(
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = base
        var entries = (base["PATH"] ?? "")
            .split(separator: ":")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if entries.isEmpty {
            entries = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        }
        for directory in ["/usr/local/bin", "/opt/homebrew/bin"] where !entries.contains(directory) {
            entries.append(directory)
        }
        environment["PATH"] = entries.joined(separator: ":")
        return environment
    }
}

private extension String {
    var preferredEditorPublicCommandName: String {
        split(separator: " ").first
            .map { URL(fileURLWithPath: String($0)).lastPathComponent } ?? "(empty)"
    }
}
