public import CmuxNextBrowser
import CmuxNextWakeups
public import Foundation
public import WebKit

/// WebKit private selectors the driver and the App's render window call,
/// behind one gate: the `@convention(c)` signatures are trusted only on the
/// macOS versions they were verified on, and every wait on a WebKit block is
/// bounded and resumes once. Owned by its callers (the WebKit driver, the
/// App's render windows), which inject the OS version, clock and bound.
public struct WebKitPrivateCalls: Sendable {
    /// macOS major versions the private signatures were verified on
    /// (cmux-lawrence-2, macOS 27.0.1, 2026-10-08). Add a version only after
    /// the same check passed on it.
    static let verifiedMajors: Set<Int> = [27]

    let osMajor: Int
    let clock: any Clock<Duration>
    /// How long a WebKit callback may take before the caller goes on.
    let callbackBound: Duration

    public init(osMajor: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
                clock: any Clock<Duration> = ContinuousClock(), callbackBound: Duration = .seconds(2)) {
        self.osMajor = osMajor
        self.clock = clock
        self.callbackBound = callbackBound
    }

    /// The private calls may run on this Mac.
    public var isVerified: Bool { Self.verifiedMajors.contains(osMajor) }

    /// Waits until the callback `register` installs runs (true), the bound
    /// passes on the clock or the task is cancelled (false). A callback that
    /// runs twice, or after the bound, does nothing.
    public func awaitCallback(register: (@escaping @Sendable () -> Void) -> Void) async -> Bool {
        let done = OneShot<Bool>()
        register { done.resolve(true) }
        // The bound is a deadline on the injected clock, cancelled once the wait ends.
        let deadline = DemandTimer(owner: "browser.webkit-private-callback", clock: clock)
        deadline.schedule(after: callbackBound) { done.resolve(false) }
        defer { deadline.cancel() }
        // concurrency-allow: OneShot.wait is an async suspension, not a blocking wait
        return await done.wait(cancelled: false)
    }

    /// Resumes once WebKit has sent the view's activity state (visible,
    /// focused, in a window) to the web process, or after the bound. On an
    /// unverified macOS, or without the selector: one JavaScript round trip
    /// (the web process handled every message sent before it).
    @MainActor
    public func afterActivityStateUpdate(_ webView: WKWebView) async {
        // crash-allow: WebKit private selector, used only after responds(to:) confirms it exists (no unknown-selector exception).
        let selector = NSSelectorFromString("_doAfterActivityStateUpdate:")
        guard isVerified, webView.responds(to: selector) else {
            _ = try? await webView.callAsyncJavaScript("return 0;", arguments: [:], in: nil, contentWorld: .defaultClient)
            return
        }
        typealias Action = @convention(block) () -> Void
        typealias Function = @convention(c) (AnyObject, Selector, Action) -> Void
        let function = unsafeBitCast(webView.method(for: selector), to: Function.self)
        _ = await awaitCallback { done in
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
    public func setOcclusionDetection(_ enabled: Bool, on webView: WKWebView) {
        // crash-allow: WebKit private selector, used only after responds(to:) confirms it exists (no unknown-selector exception).
        let selector = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        guard isVerified, webView.responds(to: selector) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        let setter = unsafeBitCast(webView.method(for: selector), to: Setter.self)
        setter(webView, selector, enabled)
    }
}
