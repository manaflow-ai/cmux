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
/// 3. A known terminal editor is rejected because a GUI process cannot
///    provide it a controlling terminal, and the file opens with the system
///    default handler instead.
/// 4. Otherwise `/bin/sh -c "<command> '<path>'"` is spawned with silenced
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
    /// Executables that require a terminal and cannot be presented by the
    /// GUI process with the preferred-editor launch path.
    static let terminalEditorNames: Set<String> = [
        "vi", "vim", "nvim", "nano", "hx", "helix", "kak",
        "kakoune", "less"
    ]

    /// Detects a known terminal editor at the executable position of a
    /// command, including common env wrappers and assignments.
    static func isTerminalEditorCommand(_ command: String) -> Bool {
        let tokens = shellWords(command)
        guard !tokens.isEmpty else { return false }

        var executableIndex = 0
        while executableIndex < tokens.count {
            let token = tokens[executableIndex]
            let basename = URL(fileURLWithPath: token).lastPathComponent

            if basename == "env" {
                executableIndex += 1
                while executableIndex < tokens.count {
                    let value = tokens[executableIndex]
                    if value == "--" {
                        executableIndex += 1
                        break
                    }
                    if value.contains("=") {
                        executableIndex += 1
                        continue
                    }
                    if value == "-S" || value == "--split-string" {
                        executableIndex += 1
                        continue
                    }
                    if value == "-u" || value == "--unset" || value == "-C"
                        || value == "--chdir" {
                        executableIndex += 2
                        continue
                    }
                    if value.hasPrefix("-") {
                        executableIndex += 1
                        continue
                    }
                    break
                }
                break
            }

            if ["exec", "command", "nice", "sudo"].contains(basename) {
                executableIndex += 1
                while executableIndex < tokens.count, tokens[executableIndex].hasPrefix("-") {
                    let option = tokens[executableIndex]
                    executableIndex += 1
                    if basename == "nice", option == "-n", executableIndex < tokens.count {
                        executableIndex += 1
                    } else if basename == "sudo",
                              ["-u", "--user", "-g", "--group", "-C", "--chdir", "-D", "--role", "--type"].contains(option),
                              executableIndex < tokens.count {
                        executableIndex += 1
                    }
                }
                continue
            }

            // Shell environment assignments may precede the executable
            // without an explicit env command.
            if token.contains("=") && !token.hasPrefix("/") {
                executableIndex += 1
                continue
            }
            break
        }

        guard executableIndex < tokens.count else { return false }
        let executable = URL(fileURLWithPath: tokens[executableIndex]).lastPathComponent
        if terminalEditorNames.contains(executable) { return true }
        // Emacs is graphical by default. Only its explicit terminal mode
        // requires a controlling terminal.
        return executable == "emacs" && tokens.dropFirst(executableIndex + 1).contains("-nw")
    }

    private static func shellWords(_ command: String) -> [String] {
        var words: [String] = [], current = "", quote: Character?, escaped = false
        for character in command {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if let activeQuote = quote {
                if character == activeQuote { quote = nil } else { current.append(character) }
            } else if character == "'" || character == "\"" { quote = character
            } else if character == " " || character == "\t" || character == "\n" {
                if !current.isEmpty { words.append(current); current = "" }
            } else { current.append(character) }
        }
        if escaped { current.append("\\") }
        if !current.isEmpty { words.append(current) }
        return words
    }

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

        // A TUI editor has no usable UI when launched from cmux's GUI process.
        // Reject it before spawning, rather than leaking the editor and its
        // plugin children with standard streams attached to /dev/null.
        guard !Self.isTerminalEditorCommand(command) else {
            systemOpener.openWithSystemDefault(url)
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "\(command) \(url.path.posixShellSingleQuoted)"]
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
