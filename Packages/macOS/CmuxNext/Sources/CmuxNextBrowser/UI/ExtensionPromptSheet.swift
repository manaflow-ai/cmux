import AppKit
import CmuxNextDesign

/// The cmux dialog for an extension prompt (`ExtensionInstallPrompt`):
/// icon, title, what the extension can do, and the two answers. It blocks
/// only the tab that asked (a tab-scope dialog) and never takes the app's
/// focus by itself.
@MainActor final class ExtensionPromptSheet {
    let prompt: ExtensionInstallPrompt
    private var dialogID: Int?
    private var completion: ((ExtensionInstallPrompt.Answer) -> Void)?

    init(prompt: ExtensionInstallPrompt) {
        self.prompt = prompt
    }

    var spec: CmuxDialogSpec {
        let deny = prompt.kind == .permissions ? Strings.extensionDeny : Strings.extensionCancel
        return CmuxDialogSpec(title: Self.title(for: prompt), lines: [Self.body(for: prompt)],
                              buttons: [CmuxDialogButton(id: "cancel", title: deny, role: .cancel),
                                        CmuxDialogButton(id: "accept", title: Self.acceptTitle(for: prompt.kind), role: .default)],
                              icon: prompt.icon, identifier: "browser.extensionPrompt.\(prompt.id)")
    }

    /// Shows the dialog in `scope`; `completion` runs once with the answer.
    func begin(in scope: CmuxDialogScope, completion: @escaping (ExtensionInstallPrompt.Answer) -> Void) {
        self.completion = completion
        dialogID = CmuxDialogCenter.shared.present(spec, in: scope) { [weak self] answer in
            self?.finish(answer.button == "accept" ? .accept : .cancel)
        }
    }

    /// Ends the dialog as if the user chose `answer` (debug socket, quit).
    func end(_ answer: ExtensionInstallPrompt.Answer) {
        guard completion != nil else { return }
        if let dialogID, CmuxDialogCenter.shared.press(dialogID, button: answer == .accept ? "accept" : "cancel") { return }
        finish(answer)
    }

    private func finish(_ answer: ExtensionInstallPrompt.Answer) {
        guard let completion else { return }
        self.completion = nil
        completion(answer)
    }

    static func title(for prompt: ExtensionInstallPrompt) -> String {
        switch prompt.kind {
        case .permissions: Strings.extensionPermissionsTitle(prompt.name)
        case .reEnable: Strings.extensionReEnableTitle(prompt.name)
        case .repair: Strings.extensionRepairTitle(prompt.name)
        case .install, .externalInstall, .remoteInstall, .other: Strings.extensionAddTitle(prompt.name)
        }
    }

    static func body(for prompt: ExtensionInstallPrompt) -> String {
        guard !prompt.permissions.isEmpty else { return Strings.extensionNoPermissions }
        let lines = prompt.permissions.map { permission -> String in
            let details = permission.details.isEmpty ? "" : "\n    " + permission.details.replacingOccurrences(of: "\n", with: "\n    ")
            return "• " + permission.message + details
        }
        return ([Strings.extensionCanHeading] + lines).joined(separator: "\n")
    }

    static func acceptTitle(for kind: ExtensionInstallPrompt.Kind) -> String {
        switch kind {
        case .permissions: Strings.extensionAllow
        case .reEnable: Strings.extensionTurnOn
        case .repair: Strings.extensionRepair
        case .install, .externalInstall, .remoteInstall, .other: Strings.extensionAdd
        }
    }
}
