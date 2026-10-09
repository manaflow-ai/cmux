public import CmuxNextBrowser
public import Foundation
public import WebKit

/// WebKit private selectors the driver and the App's render window call,
/// behind one gate: the `@convention(c)` signatures are trusted only on the
/// macOS versions they were verified on, and every wait on a WebKit block is
/// bounded and resumes once.
public enum WebKitPrivateCalls {
    /// macOS major versions the private signatures were verified on
    /// (cmux-lawrence-2, macOS 27.0.1, 2026-10-08). Add a version only after
    /// the browser-parity suite passed on it.
    static let verifiedMajors: Set<Int> = [27]

    static func isVerified(osMajor: Int) -> Bool { verifiedMajors.contains(osMajor) }

    /// The private calls may run on this Mac.
    public static var isVerifiedOS: Bool { isVerified(osMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion) }

    /// How long a WebKit callback may take before the caller goes on.
    public static let callbackBound: Duration = .seconds(2)

    /// Waits until the callback `register` installs runs (true), the bound
    /// passes on `clock` or the task is cancelled (false). A callback that
    /// runs twice, or after the bound, does nothing.
    public static func awaitCallback(bound: Duration, clock: any Clock<Duration>,
                                     register: (@escaping @Sendable () -> Void) -> Void) async -> Bool {
        let done = OneShot<Bool>()
        register { done.resolve(true) }
        let timer = Task {
            try? await clock.sleep(for: bound)
            done.resolve(false)
        }
        defer { timer.cancel() }
        return await done.wait(cancelled: false)
    }

    /// Resumes once WebKit has sent the view's activity state (visible,
    /// focused, in a window) to the web process, or after the bound. On an
    /// unverified macOS, or without the selector: one JavaScript round trip
    /// (the web process handled every message sent before it).
    @MainActor
    public static func afterActivityStateUpdate(_ webView: WKWebView, clock: any Clock<Duration>) async {
        // crash-allow: WebKit private selector, used only after responds(to:) confirms it exists (no unknown-selector exception).
        let selector = NSSelectorFromString("_doAfterActivityStateUpdate:")
        guard isVerifiedOS, webView.responds(to: selector) else {
            _ = try? await webView.callAsyncJavaScript("return 0;", arguments: [:], in: nil, contentWorld: .defaultClient)
            return
        }
        typealias Action = @convention(block) () -> Void
        typealias Function = @convention(c) (AnyObject, Selector, Action) -> Void
        let function = unsafeBitCast(webView.method(for: selector), to: Function.self)
        _ = await awaitCallback(bound: callbackBound, clock: clock) { done in
            // WebKit keeps the block until the update: it must be an escaping one.
            let action: Action = { done() }
            function(webView, selector, action)
        }
    }

    /// Turns WebKit's window occlusion detection on or off for `webView`.
    /// With it on, a window no pixel of which is on a display counts as
    /// occluded and the page stops rendering. On an unverified macOS nothing
    /// changes (a parked page may then pause while occluded).
    @MainActor
    public static func setOcclusionDetection(_ enabled: Bool, on webView: WKWebView) {
        // crash-allow: WebKit private selector, used only after responds(to:) confirms it exists (no unknown-selector exception).
        let selector = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        guard isVerifiedOS, webView.responds(to: selector) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        let setter = unsafeBitCast(webView.method(for: selector), to: Setter.self)
        setter(webView, selector, enabled)
    }
}
