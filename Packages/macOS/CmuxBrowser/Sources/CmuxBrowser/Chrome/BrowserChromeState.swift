public import Observation

/// Owns the mutable browser chrome policy for one browser pane.
///
/// A pane keeps this model for its entire lifetime. Views observe it directly,
/// while persistence stores only its ``visibility`` value.
@MainActor
@Observable
public final class BrowserChromeState {
    /// The pane's current browser chrome policy.
    public private(set) var visibility: BrowserChromeVisibility

    /// Page content is fullscreen in the pane (an HTML5 video's fullscreen
    /// button in a Chromium page): the chrome steps aside so the page fills
    /// the pane. Transient; ``visibility`` (what persistence stores) keeps the
    /// pane's own policy. cmux Next: `BrowserChromeView` hides its toolbar
    /// while `isContentFullscreen`.
    public private(set) var isContentFullscreen = false

    /// Whether the pane should render its address bar and toolbar.
    public var isOmnibarVisible: Bool {
        visibility.isOmnibarVisible && !isContentFullscreen
    }

    /// Creates pane-owned browser chrome state.
    ///
    /// - Parameter visibility: Initial chrome policy. The default preserves the
    ///   standard browser experience.
    public init(visibility: BrowserChromeVisibility = .visible) {
        self.visibility = visibility
    }

    /// Replaces the pane's chrome policy.
    ///
    /// - Parameter visibility: The new chrome policy.
    /// - Returns: `true` when the policy changed.
    @discardableResult
    public func setVisibility(_ visibility: BrowserChromeVisibility) -> Bool {
        guard self.visibility != visibility else { return false }
        self.visibility = visibility
        return true
    }

    /// Records that page content entered or left fullscreen.
    ///
    /// - Parameter fullscreen: Whether page content is fullscreen.
    /// - Returns: `true` when the state changed.
    @discardableResult
    public func setContentFullscreen(_ fullscreen: Bool) -> Bool {
        guard isContentFullscreen != fullscreen else { return false }
        isContentFullscreen = fullscreen
        return true
    }

    /// Applies a user-requested omnibar visibility change when policy permits it.
    ///
    /// - Parameter visible: Whether browser chrome should be visible.
    /// - Returns: `true` when the policy changed.
    @discardableResult
    public func setOmnibarVisible(_ visible: Bool) -> Bool {
        guard visibility.allowsOmnibarToggle else { return false }
        return setVisibility(BrowserChromeVisibility(omnibarVisible: visible))
    }

    /// Toggles browser chrome when the pane policy permits it.
    ///
    /// - Returns: The resulting omnibar visibility. A chromeless pane remains
    ///   hidden and returns `false`.
    @discardableResult
    public func toggleOmnibarVisibility() -> Bool {
        _ = setOmnibarVisible(!visibility.isOmnibarVisible)
        return visibility.isOmnibarVisible
    }
}
