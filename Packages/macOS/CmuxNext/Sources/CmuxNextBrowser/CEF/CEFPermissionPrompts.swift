import Foundation

/// Chromium permission requests cmux asks about in the prompt bar
/// (PERMISSION_PROMPT, `CEFShim/src/shim_permissions.mm`): location, and with
/// the feature `chromiumPermissionPromptsFromData` every permission prompt,
/// camera and microphone included (`CEFPermissionRequest`). Each is decided
/// with the shared store like WebKit's (`SitePermissionRequest`); Chromium
/// remembers Allow and Block itself as well. A capture the site is allowed
/// asks macOS for it in cmux's name first (`CEFCaptureAccess`).
struct CEFPermissionPrompts {
    /// Questions Chromium still waits on, by token: a question whose request
    /// Chromium ended while the store loaded never reaches the bar.
    private static var waiting: [Int32: BrowserPermissionKind] = [:]

    let tab: CEFTab
    let capture: any CEFCaptureAccess

    init(tab: CEFTab, capture: any CEFCaptureAccess = SystemCaptureAccess()) {
        self.tab = tab
        self.capture = capture
    }

    func handle(_ event: CEFShimEvent) {
        switch event {
        case .permissionPrompt(_, let token, let permissions, let origin):
            ask(token: token, request: CEFPermissionRequest(permissions: permissions), origin: origin)
        case .permissionDismissed(_, let token):
            // Chromium shows one prompt per tab at a time; its question is gone.
            guard let kind = Self.waiting.removeValue(forKey: token) else { return }
            for prompt in tab.pendingPrompts where prompt.kind == .permission(kind) { prompt.respond(.cancel) }
        case .passwordPrompt(_, let promptID, let json):
            CEFPasswordPrompts(tab: tab).arrived(promptID: promptID, json: json)
        default:
            break
        }
    }

    private func ask(token: Int32, request: CEFPermissionRequest, origin: String) {
        let runtime = tab.runtime
        guard let kind = request.kind, let site = URL(string: origin).flatMap(PageInfoSite.origin(of:)) else {
            return runtime.permissionContinue(token, .dismiss)
        }
        tab.pageInfoActivity.recordRequest(kind.requestedSiteKinds)
        Self.waiting[token] = kind
        let tab = tab
        let ask: @MainActor (BrowserPromptKind, String, @escaping (BrowserPromptResponse) -> Void) -> Void = { kind, origin, answer in
            guard Self.waiting[token] != nil else { return answer(.cancel) }
            tab.enqueuePrompt(kind, origin: origin, completion: answer)
        }
        let capture = capture
        let confirm: @MainActor (SitePermissionRequest.Outcome) async -> SitePermissionRequest.Outcome = { outcome in
            await Self.confirm(outcome, kind: kind, capture: capture)
        }
        SitePermissionRequest(kind: kind, origin: site, store: tab.sitePermissions).decide(ask: ask, confirm: confirm) { outcome in
            Self.waiting.removeValue(forKey: token)
            runtime.permissionContinue(token, outcome)
        }
    }

    /// The answer Chromium gets for the person's `outcome`. An allowed
    /// capture first asks macOS for the camera or microphone in cmux's name
    /// (Chrome asks in the same order,
    /// chrome/browser/media/webrtc/system_media_capture_permissions_mac.mm),
    /// then stays Allow whatever macOS says: Chromium checks macOS's access
    /// itself when the page captures, so a camera macOS blocks fails
    /// getUserMedia instead of being remembered as Block for the site. Block,
    /// a dismissed question and a kind with no capture never ask macOS.
    @MainActor
    static func confirm(_ outcome: SitePermissionRequest.Outcome, kind: BrowserPermissionKind,
                        capture: any CEFCaptureAccess) async -> SitePermissionRequest.Outcome {
        let captures = CEFCapture.needed(by: kind)
        guard outcome == .grant, !captures.isEmpty else { return outcome }
        await capture.authorize(captures)
        return outcome
    }
}
