import Foundation

/// Chromium permission requests cmux asks about in the prompt bar
/// (location; PERMISSION_PROMPT, `CEFShim/src/shim_permissions.mm`), decided
/// with the shared store like WebKit's (`SitePermissionRequest`). Chromium
/// remembers Allow and Block itself as well.
struct CEFPermissionPrompts {
    /// `CEF_PERMISSION_TYPE_GEOLOCATION`.
    static let geolocation: Int64 = 1 << 8

    let tab: CEFTab

    func handle(_ event: CEFShimEvent) {
        switch event {
        case .permissionPrompt(_, let token, let permissions, let origin):
            ask(token: token, permissions: permissions, origin: origin)
        case .permissionDismissed:
            // Chromium shows one prompt per tab at a time; its question is gone.
            for prompt in tab.pendingPrompts where prompt.kind == .permission(.location) { prompt.respond(.cancel) }
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
        SitePermissionRequest(kind: .location, origin: site, store: tab.sitePermissions)
            .decide(ask: tab.enqueuePrompt) { runtime.permissionContinue(token, $0) }
    }
}
