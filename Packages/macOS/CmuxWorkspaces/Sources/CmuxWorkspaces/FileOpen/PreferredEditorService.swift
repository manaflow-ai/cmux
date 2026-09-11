public import Foundation
public import CmuxSettings
public import CmuxTestSupport

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
///    stdio; a launch failure or a nonzero exit (e.g. command-not-found
///    exiting 127) falls back to the system default handler.
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
        open(url, line: nil, column: nil)
    }

    /// Opens `url` at an optional 1-based line (and column) locator.
    ///
    /// When a line is given and a command is configured, the argument is the
    /// `path:line[:col]` locator form that Zed, VS Code (`code`), and Sublime
    /// accept. The capture seam and the system-default fallback always receive
    /// the bare path — non-editor handlers cannot take a position.
    public func open(_ url: URL, line: Int?, column: Int?) {
        if capture.appendLineIfConfigured(
            envKey: "CMUX_UI_TEST_CAPTURE_OPEN_PATH",
            line: url.path
        ) {
            return
        }

        guard let command = editor.resolvedCommand else {
            systemOpener.openWithSystemDefault(url)
            return
        }

        var argument = url.path
        if let line {
            argument += ":\(line)"
            if let column {
                argument += ":\(column)"
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "\(command) \(argument.posixShellSingleQuoted)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let systemOpener = self.systemOpener
        process.terminationHandler = { @Sendable process in
            // Fall back when the command fails (e.g. command not found exits
            // 127 but /bin/sh itself launched fine).
            guard process.terminationStatus != 0 else { return }
            Task { @MainActor in
                systemOpener.openWithSystemDefault(url)
            }
        }

        do {
            try process.run()
        } catch {
            systemOpener.openWithSystemDefault(url)
        }
    }
}
