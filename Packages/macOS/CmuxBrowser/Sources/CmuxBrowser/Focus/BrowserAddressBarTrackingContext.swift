/// The focus signals that decide whether browser address-bar tracking survives a
/// WebView focus change.
///
/// The app target gathers these six booleans from the live `BrowserPanel`,
/// omnibar field registry, and first responder, then asks whether the tracked
/// address bar should be preserved while the WebView is gaining focus. The
/// decision is a pure function of these inputs with no AppKit or `BrowserPanel`
/// reach, so it lives here next to the omnibar focus decisions that consume it.
public struct BrowserAddressBarTrackingContext: Equatable, Sendable {
    /// Whether the panel that owns the tracked address bar matches the WebView
    /// receiving focus.
    public let trackedPanelMatchesWebView: Bool
    /// Whether an omnibar responder is already the first responder.
    public let omnibarResponderActive: Bool
    /// Whether the panel's preferred focus intent is the address bar.
    public let preferredFocusIntentIsAddressBar: Bool
    /// Whether the panel currently suppresses WebView focus.
    public let suppressesWebViewFocus: Bool
    /// Whether the WebView focus was initiated by a pointer interaction.
    public let pointerInitiatedWebFocus: Bool
    /// Whether a live omnibar field still exists for the panel.
    public let liveOmnibarFieldExists: Bool

    /// Creates a tracking context from the six live focus signals.
    public init(
        trackedPanelMatchesWebView: Bool,
        omnibarResponderActive: Bool,
        preferredFocusIntentIsAddressBar: Bool,
        suppressesWebViewFocus: Bool,
        pointerInitiatedWebFocus: Bool,
        liveOmnibarFieldExists: Bool
    ) {
        self.trackedPanelMatchesWebView = trackedPanelMatchesWebView
        self.omnibarResponderActive = omnibarResponderActive
        self.preferredFocusIntentIsAddressBar = preferredFocusIntentIsAddressBar
        self.suppressesWebViewFocus = suppressesWebViewFocus
        self.pointerInitiatedWebFocus = pointerInitiatedWebFocus
        self.liveOmnibarFieldExists = liveOmnibarFieldExists
    }

    /// Whether address-bar tracking should be preserved while the WebView gains focus.
    ///
    /// Decision order:
    /// 1. Reject WebView focus from another panel.
    /// 2. Preserve if an omnibar responder is already active.
    /// 3. Require address-bar focus intent.
    /// 4. Let pointer-initiated WebView focus clear tracking.
    /// 5. Preserve if WebView focus is suppressed or a live omnibar field exists.
    public var shouldPreserveAddressBarTrackingDuringWebViewFocus: Bool {
        guard trackedPanelMatchesWebView else { return false }
        if omnibarResponderActive { return true }
        guard preferredFocusIntentIsAddressBar else { return false }
        guard !pointerInitiatedWebFocus else { return false }
        return suppressesWebViewFocus || liveOmnibarFieldExists
    }
}
