import Foundation

/// Chromium permission requests cmux asks about in the prompt bar
/// (location, camera, microphone; PERMISSION_PROMPT,
/// `CEFShim/src/shim_permissions.mm`), decided
/// with the shared store like WebKit's (`SitePermissionRequest`). Chromium
/// remembers Allow and Block itself as well.
struct CEFPermissionPrompts {
    /// `CEF_PERMISSION_TYPE_GEOLOCATION`.
    static let geolocation: Int64 = 1 << 8
    /// `CEF_PERMISSION_TYPE_CAMERA_STREAM`, `_CAMERA_PAN_TILT_ZOOM`, `_MIC_STREAM`.
    static let camera: Int64 = 1 << 2
    static let cameraPanTiltZoom: Int64 = 1 << 1
    static let microphone: Int64 = 1 << 12

    /// Not a CEF bit: the shim sends it for getDisplayMedia() (`kPermissionDisplayCapture`).
    static let displayCapture: Int64 = 1 << 30

    /// The prompt-bar question for a request's bits (`kHostPermissions` in
    /// `permission_prompt_policy.h`); nil for a set the bar does not ask.
    /// Chromium groups a page's camera and microphone into one request,
    /// and pan-tilt-zoom comes with the camera.
    static func kind(of permissions: Int64) -> BrowserPermissionKind? {
        if permissions == geolocation { return .location }
        if permissions == displayCapture { return .screenShare }
        guard permissions != 0, permissions & ~(camera | cameraPanTiltZoom | microphone) == 0 else { return nil }
        let wantsCamera = permissions & (camera | cameraPanTiltZoom) != 0
        let wantsMicrophone = permissions & microphone != 0
        switch (wantsCamera, wantsMicrophone) {
        case (true, true): return .cameraAndMicrophone
        case (true, false): return .camera
        default: return .microphone
        }
    }

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
            for prompt in tab.pendingPrompts where prompt.kind.isChromiumPermission { prompt.respond(.cancel) }
        case .passwordPrompt(_, let promptID, let json):
            CEFPasswordPrompts(tab: tab).arrived(promptID: promptID, json: json)
        default:
            break
        }
    }

    private func ask(token: Int32, permissions: Int64, origin: String) {
        let runtime = tab.runtime
        guard let kind = Self.kind(of: permissions), let site = URL(string: origin).flatMap(PageInfoSite.origin(of:)) else {
            return runtime.permissionContinue(token, .dismiss)
        }
        tab.pageInfoActivity.recordRequest(kind.siteKinds)
        Self.waiting.insert(token)
        let tab = tab
        if kind == .screenShare {
            // Sharing the screen is asked every time and never remembered for the site.
            tab.enqueuePrompt(.permission(kind), origin: site) { response in
                Self.waiting.remove(token)
                runtime.permissionContinue(token, response == .allowOnce || response == .allow ? .grant : .deny)
            }
            return
        }
        let ask: @MainActor (BrowserPromptKind, String, @escaping (BrowserPromptResponse) -> Void) -> Void = { kind, origin, answer in
            guard Self.waiting.contains(token) else { return answer(.cancel) }
            tab.enqueuePrompt(kind, origin: origin, completion: answer)
        }
        SitePermissionRequest(kind: kind, origin: site, store: tab.sitePermissions).decide(ask: ask) { outcome in
            Self.waiting.remove(token)
            runtime.permissionContinue(token, outcome)
        }
    }
}

private extension BrowserPromptKind {
    /// A question `CEFPermissionPrompts` puts in the bar for Chromium.
    var isChromiumPermission: Bool {
        switch self {
        case .permission(.location), .permission(.camera), .permission(.microphone), .permission(.cameraAndMicrophone), .permission(.screenShare): true
        default: false
        }
    }
}
