import AppKit
import CmuxNextCodeRouter
import CmuxNextDesign

/// The missing-access card's Add API key dialog: one secure field for the provider's key, a cmux
/// dialog over the chat's window. The key is returned to the caller only; it is never shown again,
/// logged or put in the page.
@MainActor
struct AgentPaneAPIKeySheet {
    /// The window the dialog blocks; nil shows it app-wide.
    let window: NSWindow?

    static let field = "apiKey"
    static let save = "save"

    /// The key the person pasted (surrounding whitespace dropped), or nil when they cancelled.
    func ask(for provider: AIProvider) async -> String? {
        let spec = CmuxDialogSpec(
            title: AgentPaneAccessStrings.keyTitle(provider.displayName),
            lines: [AgentPaneAccessStrings.keyMessage(provider.displayName)],
            fields: [.text(id: Self.field, label: nil, initial: "", placeholder: AgentPaneAccessStrings.keyPlaceholder, secure: true)],
            buttons: [.cancel(AgentPaneAccessStrings.keyCancel),
                      CmuxDialogButton(id: Self.save, title: AgentPaneAccessStrings.keySave, role: .default)],
            identifier: "cmux.access.apiKey")
        let scope: CmuxDialogScope = if let window { .window(window) } else { .app }
        let answer = await CmuxDialogCenter.shared.present(spec, in: scope)
        guard answer.button == Self.save, !answer.isDismissal else { return nil }
        let key = answer.text(Self.field)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return key.isEmpty ? nil : key
    }
}
