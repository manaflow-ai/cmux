import AppKit
import CmuxNextDesign
import Security

/// Passkeys for Chromium pages nobody sees (a detached or remote-presentation page) and for tabs in
/// `CMUX_WEBAUTHN_MODE_DELEGATE` (fork API 33; cef_cmux.h `cmux_set_webauthn_delegate`). Chromium
/// sends such a page's `navigator.credentials.create` / `get` here after its own origin, RP ID and
/// TLS checks. cmux asks the person first, in the visible cmux window that holds the tab: the real
/// origin and RP ID, create or sign in, whether an agent drives the tab, and whether the page asked by
/// itself (no click or key press, which an agent's input also gives). After Continue the system
/// passkey sheet runs in that window (`CEFWebAuthnCeremony`) and the credential goes back to the
/// page through `cmux_webauthn_complete`, which checks it against the request first. The engine
/// owns the one instance (`CEFEngine.webAuthn`).
///
/// A fork without the two calls (API 30), or a build without the browser passkey entitlement (DEV
/// builds), gets no delegate: its detached pages keep refusing with NotAllowedError, as before. Conditional (autofill) requests stay refused
/// (`conditional_mediation` 0) until cmux offers passkeys in its own autofill.
@MainActor
final class CEFWebAuthnPrompts {
    /// The dialog's identifier: only the person answers it (`DebugDialog.userOnly` in the App lists it).
    static let dialogIdentifier = "browser.webauthnRequest"
    static let entitlement = "com.apple.developer.web-browser.public-key-credential"

    private enum Stage {
        case asking(dialog: Int)
        case authorizing
        case running(CEFWebAuthnCeremony)
    }

    private var pending: [Int32: Stage] = [:]
    private var installed = false

    /// Sets the delegate once Chromium runs (`CEFEngine.onReady`); does nothing on a fork without it.
    /// The delegate's context holds this object for the rest of the process (the engine owns it too).
    func install() {
        let runtime = CEFRuntime.shared
        guard !installed, runtime.state == .ready, let set = runtime.shim?.webAuthnSetDelegate else { return }
        installed = true
        // AuthenticationServices' browser requests (both providers) need the browser passkey
        // entitlement, which only signed release builds carry. Without it cmux sets no delegate:
        // pages nobody sees refuse with NotAllowedError as before, and agent tabs keep Chromium's
        // own WebAuthn UI (`CEFWebAuthnMode`), instead of a prompt whose ceremony always fails.
        guard Self.entitled else {
            return runtime.logger.notice("WebAuthn delegate not set: this build lacks \(Self.entitlement, privacy: .public)")
        }
        let platform: Int32 = WebKitPasskeyAuthorization.shared.state != .denied ? 1 : 0
        let context = Unmanaged.passRetained(self).toOpaque()
        let result = set(CEFWebAuthnCallbacks.request, CEFWebAuthnCallbacks.cancel, context, platform)
        runtime.logger.notice("WebAuthn delegate \(result == 1 ? "set" : "not available (fork without API 33)", privacy: .public) platform=\(platform)")
    }

    /// Whether this app may run browser passkey ceremonies (signed builds; tagged DEV builds lack it).
    static let entitled: Bool = {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, entitlement as CFString, nil) as? Bool == true
    }()

    // MARK: Requests

    func arrived(json: String) {
        guard let request = CEFWebAuthnRequest(json: json) else {
            if let id = Self.requestID(in: json) { complete(id, error: "NotAllowedError", "cmux could not read this request.") }
            return
        }
        // Conditional, immediate and ambient requests never show modal UI; cmux has no autofill for them yet.
        guard request.mediation == .modal else {
            return complete(request.id, error: "NotAllowedError", "cmux offers passkeys only after a prompt.")
        }
        let tab = CEFRuntime.shared.tabsByBrowser[request.browserID]
        guard let (placement, window) = scope(for: tab) else {
            return complete(request.id, error: "NotAllowedError", "No cmux window can show this request.")
        }
        var shown = false
        if case .tab = placement { shown = true }
        let spec = Self.spec(for: request, tab: tab, tabShown: shown)
        let dialog = CmuxDialogCenter.shared.present(spec, in: placement) { [weak self] answer in
            self?.answered(request, continued: answer.button == "continue", window: window)
        }
        pending[request.id] = .asking(dialog: dialog)
        // Never takes focus: the Dock icon asks for attention when cmux is in the background.
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        CEFRuntime.shared.logger.notice("WebAuthn request \(request.id) \(request.kind == .create ? "create" : "get", privacy: .public) browser=\(request.browserID) detached=\(request.detached)")
    }

    /// Chromium ended a request without cmux's answer (abort, timeout, the document is gone).
    func cancelled(_ id: Int32) {
        switch pending.removeValue(forKey: id) {
        case .asking(let dialog): CmuxDialogCenter.shared.dismiss(dialog)
        case .running(let ceremony): ceremony.cancel()
        case .authorizing, nil: break
        }
    }

    private func answered(_ request: CEFWebAuthnRequest, continued: Bool, window: NSWindow) {
        guard case .asking = pending[request.id] else { return }
        guard continued else {
            pending[request.id] = nil
            return complete(request.id, error: "NotAllowedError", "The person declined.")
        }
        pending[request.id] = .authorizing
        // task-owner: one main-actor hop while the system asks once for passkey access; a cancel meanwhile drops it.
        Task { @MainActor [weak self] in
            let state = Self.entitled ? await WebKitPasskeyAuthorization.shared.requestIfNeeded() : .denied
            self?.run(request, platform: state == .authorized, window: window)
        }
    }

    private func run(_ request: CEFWebAuthnRequest, platform: Bool, window: NSWindow) {
        guard case .authorizing = pending[request.id] else { return }
        let ceremony = CEFWebAuthnCeremony(request: request, window: window)
        pending[request.id] = .running(ceremony)
        ceremony.start(platform: platform) { [weak self] outcome in
            guard let self, case .running = pending.removeValue(forKey: request.id) else { return }
            switch outcome {
            case .credential(let json): complete(request.id, json: json)
            case .failure(let name, let message): complete(request.id, error: name, message)
            }
        }
    }

    private func complete(_ id: Int32, json: String? = nil, error name: String? = nil, _ message: String? = nil) {
        let runtime = CEFRuntime.shared
        guard let answer = runtime.shim?.webAuthnComplete else { return }
        let result = answer(id, json, name, message)
        if result == -1 { runtime.logger.error("WebAuthn request \(id): the credential failed the fork's checks; the page got NotAllowedError") }
    }

    private static func requestID(in json: String) -> Int32? {
        let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        return (object?["request_id"] as? Int).map { Int32(truncatingIfNeeded: $0) }
    }

    /// The tab that asked when the person can see it (only that tab is blocked); else its window, the
    /// window that showed a Chromium tab last, or any visible cmux window.
    private func scope(for tab: CEFTab?) -> (CmuxDialogScope, NSWindow)? {
        if let view = tab?.contentView, let window = view.window, window.isVisible, !view.isHiddenOrHasHiddenAncestor {
            return (.tab(view), window)
        }
        let candidates = [tab?.contentView.window, CEFRuntime.shared.lastShownHost?.visibleTab?.contentView.window]
        if let window = candidates.compactMap(\.self).first(where: \.isVisible) { return (.window(window), window) }
        let window = NSApp.windows.first { $0.isVisible && $0.parent == nil && !($0 is NSPanel) && $0.canBecomeMain }
        return window.map { (.window($0), $0) }
    }

    // MARK: The dialog

    static func spec(for request: CEFWebAuthnRequest, tab: CEFTab?, tabShown: Bool) -> CmuxDialogSpec {
        var lines: [String] = []
        if request.crossOrigin { lines.append(Strings.webAuthnFrame(request.topOrigin)) }
        if !tabShown, let tab {
            let name = tab.state.title.flatMap { $0.isEmpty ? nil : $0 } ?? tab.state.url?.host() ?? request.origin
            lines.append(Strings.webAuthnTab(name))
        }
        if tab?.isAgentDriven == true { lines.append(Strings.webAuthnAgent) }
        if !request.userActivation { lines.append(Strings.webAuthnNoGesture) }
        if request.detached { lines.append(Strings.webAuthnNotOnScreen) }
        lines.append(request.kind == .create ? Strings.webAuthnCreateNext : Strings.webAuthnSignInNext)
        return CmuxDialogSpec(
            title: request.kind == .create ? Strings.webAuthnCreateTitle(request.rpID) : Strings.webAuthnSignInTitle(request.rpID),
            lines: lines, origin: request.origin,
            buttons: [CmuxDialogButton(id: "cancel", title: Strings.webAuthnCancel, role: .cancel),
                      CmuxDialogButton(id: "continue", title: Strings.webAuthnContinue, role: .default)],
            identifier: dialogIdentifier)
    }
}
