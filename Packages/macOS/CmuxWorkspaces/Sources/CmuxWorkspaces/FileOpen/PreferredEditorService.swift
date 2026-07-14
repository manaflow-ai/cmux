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

    /// Opens a file, carrying a one-based source location to editor commands.
    ///
    /// Configured commands receive one shell-quoted `path:line[:column]`
    /// argument. Commands that support source locations can navigate directly;
    /// UI-test capture records that same argument, while the system fallback
    /// still receives the plain file URL.
    ///
    /// - Parameters:
    ///   - url: The local file URL to open.
    ///   - line: An optional one-based line.
    ///   - column: An optional one-based column, used only when `line` exists.
    public func open(_ url: URL, line: Int?, column: Int?) {
        let editorArgument: String
        if let line {
            if let column {
                editorArgument = "\(url.path):\(line):\(column)"
            } else {
                editorArgument = "\(url.path):\(line)"
            }
        } else {
            editorArgument = url.path
        }

        if capture.appendLineIfConfigured(
            envKey: "CMUX_UI_TEST_CAPTURE_OPEN_PATH",
            line: editorArgument
        ) {
            return
        }

        guard let command = editor.resolvedCommand else {
            systemOpener.openWithSystemDefault(url)
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "\(command) \(editorArgument.posixShellSingleQuoted)"]
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
