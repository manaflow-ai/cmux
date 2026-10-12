import Foundation
import os

/// Agents never complete a passkey ceremony (plans/cmux-next/passkeys.md
/// 3.5): Chromium refuses every WebAuthn request of a tab an agent drives
/// (cmux_tab_set_webauthn_mode, fork API 23) with NotAllowedError before any
/// authenticator or system UI, and the prompt bar tells the person, with
/// "Sign in yourself". An older fork has no refuse mode: requests run as
/// before, and the log says so.
public enum CEFAgentPasskeys {
    static let allow: Int32 = 0
    static let refuse: Int32 = 1
    /// Debug builds' passkey matrix: browsers whose agent-driven page runs
    /// WebAuthn against a DevTools virtual authenticator (mode virtual).
    private static var virtualBrowsers: Set<Int32> = []

    /// Sends an agent-driven tab's mode, again on attach for a page that was
    /// still being created. Popups the page opens inherit it in Chromium.
    static func applyMode(_ tab: CEFTab) {
        guard tab.isAgentDriven, let browserID = tab.browserID, tab.runtime.state == .ready else { return }
        let mode = virtualBrowsers.contains(browserID) ? allow : refuse
        if tab.runtime.shim?.setWebAuthnMode(browserID, mode) != 1, mode == refuse {
            tab.runtime.logger.notice("webauthn stays on for browser \(browserID, privacy: .public): fork has no refuse mode")
        }
    }

    /// One notice per tab while it is open, however often the page retries.
    static func refused(_ tab: CEFTab) {
        guard !tab.pendingPrompts.contains(where: { $0.kind == .agentPasskeyRefused }) else { return }
        let origin = (tab.committedURL ?? tab.state.url).flatMap(PageInfoSite.origin(of:)) ?? ""
        tab.enqueuePrompt(.agentPasskeyRefused, origin: origin) { [weak tab] response in
            guard response == .accept, let tab else { return }
            tab.delegate?.browserTab(tab, didRequest: .endAgentControl)
        }
    }

    /// Debug builds: WebAuthn of agent-driven `tab` runs (against the
    /// DevTools virtual authenticator the caller attaches) until `false` or
    /// WebAuthn.disable through `debug.cef.devtools`.
    public static func setVirtual(_ tab: CEFTab, _ on: Bool) {
        guard let browserID = tab.browserID else { return }
        if on { virtualBrowsers.insert(browserID) } else { virtualBrowsers.remove(browserID) }
        applyMode(tab)
    }
}
