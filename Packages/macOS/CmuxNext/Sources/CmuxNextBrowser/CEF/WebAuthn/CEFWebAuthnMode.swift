import Foundation

/// An agent-driven tab's passkey requests go to cmux's prompt (`CMUX_WEBAUTHN_MODE_DELEGATE`, fork
/// API 33), also while the page shows: the person sees which site asks and that an agent drives the
/// tab, and answers in cmux before the system sheet runs (`CEFWebAuthnPrompts`). The mode stays for
/// the page's life, as the tab's other agent-driven rules do (password fill, `CEFAgentURLGuard`).
/// Without cmux's delegate (a fork before API 33, a build without the browser passkey entitlement)
/// the shim leaves the tab's mode alone, so Chromium's own WebAuthn UI keeps working there.
enum CEFWebAuthnMode {
    /// Applied when the browser attaches and when the tab becomes agent-driven (`CEFAgentURLGuard`).
    static func apply(_ tab: CEFTab, browser: Int32) {
        guard tab.isAgentDriven, tab.runtime.state == .ready, let delegate = tab.runtime.shim?.webAuthnDelegateTab else { return }
        if delegate(browser) != 1 { tab.runtime.logger.notice("WebAuthn: browser \(browser) keeps its mode (no cmux delegate)") }
    }
}

extension CEFShimLibrary {
    /// `cmux_shim_webauthn_request_fn` (ctx, request JSON) and `cmux_shim_webauthn_cancel_fn` (ctx, id, reason).
    typealias WebAuthnRequestFn = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void
    typealias WebAuthnCancelFn = @convention(c) (UnsafeMutableRawPointer?, Int32, Int32) -> Void
}
