import CmuxNextDesign
import Foundation

extension AgentPaneView {
    /// The native Enable harness sheet for `prompt` (BRING-YOUR-OWN-HARNESS H4): the file, the
    /// folder, the exact command line, the program it resolves to, each env key with its source,
    /// the checked files, acpmux's warnings and the hash. Every value is shown with its control and
    /// bidi characters written out. Enable is not the Return key's button: the user clicks it.
    static func harnessEnableSpec(_ prompt: AgentPaneHarnessEnablePrompt) -> CmuxDialogSpec {
        let show = AgentPaneHarnessEnablePrompt.visible
        var lines = [String(format: harnessEnableMessage, show(prompt.folder))]
        lines.append(String(format: harnessEnableFile, show(prompt.path)))
        lines.append(String(format: harnessEnableCommand, show(prompt.commandLine)))
        lines.append(prompt.program.map { String(format: harnessEnableProgram, show($0)) } ?? harnessEnableNoProgram)
        if prompt.env.isEmpty { lines.append(harnessEnableNoEnv) }
        for entry in prompt.env {
            switch entry.source {
            case .plain(let value): lines.append(String(format: harnessEnableEnvPlain, show(entry.key), show(value)))
            case .keychain(let item): lines.append(String(format: harnessEnableEnvKeychain, show(entry.key), show(item)))
            case .login(let variable): lines.append(String(format: harnessEnableEnvLogin, show(entry.key), show(variable)))
            }
        }
        for file in prompt.checkedFiles { lines.append(String(format: harnessEnableChecked, show(file))) }
        for warning in prompt.warnings { lines.append(String(format: harnessEnableWarning, show(warning))) }
        lines.append(String(format: harnessEnableHash, show(prompt.sha256)))
        return CmuxDialogSpec(title: String(format: harnessEnableTitle, show(prompt.id)), lines: lines,
                              buttons: [.cancel(), CmuxDialogButton(id: "enable", title: harnessEnableButton, role: .destructive)],
                              identifier: harnessEnableIdentifier)
    }

    /// The sheet's dialog identifier. Only the user answers it: `debug.dialog` may dismiss it
    /// (which refuses), never press Enable, so an agent with the debug socket cannot enable a
    /// folder's program by itself.
    public static let harnessEnableIdentifier = "agentPane.enableHarness"

    /// `%@` is the profile's id.
    static var harnessEnableTitle: String {
        String(localized: "agentPane.enableHarness.title", defaultValue: "Enable harness %@?", bundle: .module)
    }

    /// `%@` is the folder.
    static var harnessEnableMessage: String {
        String(localized: "agentPane.enableHarness.message",
               defaultValue: "A file in %@ asks to run this program with your rights in chats inside that folder. Enable it only if you trust every line below.",
               bundle: .module)
    }

    static var harnessEnableFile: String {
        String(localized: "agentPane.enableHarness.file", defaultValue: "File: %@", bundle: .module)
    }

    static var harnessEnableCommand: String {
        String(localized: "agentPane.enableHarness.command", defaultValue: "Command: %@", bundle: .module)
    }

    static var harnessEnableProgram: String {
        String(localized: "agentPane.enableHarness.program", defaultValue: "Program: %@", bundle: .module)
    }

    static var harnessEnableNoProgram: String {
        String(localized: "agentPane.enableHarness.noProgram", defaultValue: "Program: not found on PATH now", bundle: .module)
    }

    static var harnessEnableNoEnv: String {
        String(localized: "agentPane.enableHarness.noEnv", defaultValue: "Environment: none", bundle: .module)
    }

    /// `%1$@` is the env key, `%2$@` its plain value.
    static var harnessEnableEnvPlain: String {
        String(localized: "agentPane.enableHarness.envPlain", defaultValue: "Environment %1$@ = %2$@", bundle: .module)
    }

    /// `%1$@` is the env key, `%2$@` the Keychain item's name.
    static var harnessEnableEnvKeychain: String {
        String(localized: "agentPane.enableHarness.envKeychain", defaultValue: "Environment %1$@ = Keychain item %2$@", bundle: .module)
    }

    /// `%1$@` is the env key, `%2$@` the login variable's name.
    static var harnessEnableEnvLogin: String {
        String(localized: "agentPane.enableHarness.envLogin", defaultValue: "Environment %1$@ = your login variable %2$@", bundle: .module)
    }

    static var harnessEnableChecked: String {
        String(localized: "agentPane.enableHarness.checked", defaultValue: "Checked file: %@ (a change asks again)", bundle: .module)
    }

    static var harnessEnableWarning: String {
        String(localized: "agentPane.enableHarness.warning", defaultValue: "Warning: %@", bundle: .module)
    }

    static var harnessEnableHash: String {
        String(localized: "agentPane.enableHarness.hash", defaultValue: "SHA-256: %@", bundle: .module)
    }

    static var harnessEnableButton: String {
        String(localized: "agentPane.enableHarness.enable", defaultValue: "Enable Harness", bundle: .module)
    }
}
