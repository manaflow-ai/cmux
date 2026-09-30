import AppKit

/// The native sheet for an extension prompt (`ExtensionInstallPrompt`):
/// icon, title, what the extension can do, and the two answers. It attaches
/// to the window of the tab that asked, like Chrome's tab-modal dialog, and
/// never takes the app's focus by itself (a sheet on a no-activate window
/// stays inactive until the user clicks it).
@MainActor final class ExtensionPromptSheet {
    let prompt: ExtensionInstallPrompt
    private let alert = NSAlert()
    private weak var window: NSWindow?
    private var completion: ((ExtensionInstallPrompt.Answer) -> Void)?

    init(prompt: ExtensionInstallPrompt) {
        self.prompt = prompt
        alert.messageText = Self.title(for: prompt)
        alert.informativeText = Self.body(for: prompt)
        if let data = prompt.icon, let image = NSImage(data: data) {
            image.size = NSSize(width: 48, height: 48)
            alert.icon = image
        }
        alert.addButton(withTitle: Self.acceptTitle(for: prompt.kind))
        alert.addButton(withTitle: prompt.kind == .permissions ? Strings.extensionDeny : Strings.extensionCancel)
        alert.window.setAccessibilityIdentifier("browser.extensionPrompt.\(prompt.id)")
    }

    /// Shows the sheet on `window`; `completion` runs once with the answer.
    func begin(on window: NSWindow, completion: @escaping (ExtensionInstallPrompt.Answer) -> Void) {
        self.window = window
        self.completion = completion
        alert.beginSheetModal(for: window) { [weak self] response in
            self?.finish(response == .alertFirstButtonReturn ? .accept : .cancel)
        }
    }

    /// Ends the sheet as if the user chose `answer` (debug socket, quit).
    func end(_ answer: ExtensionInstallPrompt.Answer) {
        guard completion != nil else { return }
        let code: NSApplication.ModalResponse = answer == .accept ? .alertFirstButtonReturn : .alertSecondButtonReturn
        if let window, alert.window.sheetParent === window {
            window.endSheet(alert.window, returnCode: code)
        } else {
            finish(answer)
        }
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
