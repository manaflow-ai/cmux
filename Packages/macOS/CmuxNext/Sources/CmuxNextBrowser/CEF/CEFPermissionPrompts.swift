import Foundation

/// Chromium permission requests cmux asks about in the prompt bar
/// (location; PERMISSION_PROMPT, `CEFShim/src/shim_permissions.mm`), decided
/// with the shared store like WebKit's (`SitePermissionRequest`). Chromium
/// remembers Allow and Block itself as well. The notice of a refused agent
/// passkey request reaches the prompt bar through here too (`CEFAgentPasskeys`).
struct CEFPermissionPrompts {
    /// `CEF_PERMISSION_TYPE_GEOLOCATION`.
    static let geolocation: Int64 = 1 << 8

    /// Tokens Chromium still waits on: a question whose request Chromium
    /// ended while the store loaded never reaches the bar.
    private static var waiting: Set<Int32> = []

    let tab: CEFTab

    func handle(_ event: CEFShimEvent) {
        switch event {
        case .permissionPrompt(_, let token, let permissions, let origin):
            ask(token: token, permissions: permissions, origin: origin)
        case .permissionDismissed(_, let token):
            // Chromium shows one prompt per tab at a time; its question is gone.
            guard Self.waiting.remove(token) != nil else { return }
            for prompt in tab.pendingPrompts where prompt.kind == .permission(.location) { prompt.respond(.cancel) }
        case .passwordPrompt(_, let promptID, let json):
            CEFPasswordPrompts(tab: tab).arrived(promptID: promptID, json: json)
        case .webAuthnRefused:
            // Not a question Chromium waits on: cmux's notice of a refused agent passkey request.
            CEFAgentPasskeys.refused(tab)
        default:
            break
        }
    }

    private func ask(token: Int32, permissions: Int64, origin: String) {
        let runtime = tab.runtime
        guard permissions == Self.geolocation, let site = URL(string: origin).flatMap(PageInfoSite.origin(of:)) else {
            return runtime.permissionContinue(token, .dismiss)
        }
        tab.pageInfoActivity.recordRequest([.location])
        Self.waiting.insert(token)
        let tab = tab
        let ask: @MainActor (BrowserPromptKind, String, @escaping (BrowserPromptResponse) -> Void) -> Void = { kind, origin, answer in
            guard Self.waiting.contains(token) else { return answer(.cancel) }
            tab.enqueuePrompt(kind, origin: origin, completion: answer)
        }
        SitePermissionRequest(kind: .location, origin: site, store: tab.sitePermissions).decide(ask: ask) { outcome in
            Self.waiting.remove(token)
            runtime.permissionContinue(token, outcome)
        }
    }
}
