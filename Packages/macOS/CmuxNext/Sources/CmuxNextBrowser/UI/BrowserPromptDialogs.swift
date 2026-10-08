import AppKit
import CmuxNextDesign

/// Shows a tab's first pending prompt (R96): a JavaScript alert, confirm or
/// prompt, and an HTTP sign-in (`BrowserHTTPAuth`), is a cmux dialog that
/// blocks only this tab and names the asking origin; a permission request
/// stays in the tab's prompt bar. The prompt
/// list (`WebKitTab.pendingPrompts`) stays the model, so the automation
/// broker can answer a prompt too; the dialog then goes away. A dialog that
/// ends because the tab left the window (tab switch) does not answer the
/// page: it shows again when the tab comes back.
@MainActor
final class BrowserPromptDialogs {
    private var shown: (prompt: ObjectIdentifier, dialog: Int)?
    private let center: CmuxDialogCenter

    init(center: CmuxDialogCenter = .shared) {
        self.center = center
    }

    func render(_ prompt: BrowserPrompt?, in view: NSView, bar: PromptBarView) {
        guard let prompt, let spec = Self.spec(for: prompt) else {
            dismissShown()
            if let prompt {
                bar.show(prompt)
                bar.isHidden = false
            } else {
                bar.isHidden = true
            }
            return
        }
        bar.isHidden = true
        if shown?.prompt == ObjectIdentifier(prompt) { return }
        dismissShown()
        guard view.window != nil else { return }
        let key = ObjectIdentifier(prompt)
        let id = center.present(spec, in: .tab(view)) { [weak self, weak prompt] answer in
            if self?.shown?.prompt == key { self?.shown = nil }
            guard let prompt, !answer.isDismissal else { return }
            prompt.respond(Self.response(to: answer, for: prompt.kind))
        }
        shown = (key, id)
    }

    /// The dialog for a JavaScript dialog; nil for a permission request.
    static func spec(for prompt: BrowserPrompt) -> CmuxDialogSpec? {
        let title = Strings.dialogFrom(prompt.origin)
        let ok = CmuxDialogButton(id: "ok", title: Strings.ok, role: .default)
        let cancel = CmuxDialogButton(id: "cancel", title: Strings.cancel, role: .cancel)
        let identifier = "browser.dialog.javascript"
        switch prompt.kind {
        case .permission:
            return nil
        case .credentials(let host, let realm):
            return BrowserHTTPAuth.spec(host: host, realm: realm, isSecure: true, failedBefore: false, user: nil)
        case .alert(let message):
            return CmuxDialogSpec(title: title, lines: [message], buttons: [ok], identifier: identifier)
        case .confirm(let message):
            return CmuxDialogSpec(title: title, lines: [message], buttons: [cancel, ok], identifier: identifier)
        case .textInput(let message, let defaultText):
            return CmuxDialogSpec(title: title, lines: [message],
                                  fields: [.text("text", initial: defaultText ?? "")], buttons: [cancel, ok], identifier: identifier)
        }
    }

    static func response(to answer: CmuxDialogAnswer, for kind: BrowserPromptKind) -> BrowserPromptResponse {
        switch kind {
        case .textInput: answer.button == "ok" ? .text(answer.text("text") ?? "") : .cancel
        case .credentials:
            BrowserHTTPAuth.credential(for: answer).map {
                .credentials(user: $0.user ?? "", password: $0.password ?? "", remember: $0.persistence == .permanent)
            } ?? .cancel
        default: answer.button == "ok" ? .accept : .cancel
        }
    }

    private func dismissShown() {
        guard let shown else { return }
        self.shown = nil
        center.dismiss(shown.dialog)
    }
}
