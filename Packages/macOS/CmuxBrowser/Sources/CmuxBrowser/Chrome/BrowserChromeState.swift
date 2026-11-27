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

    /// Whether the pane should render its address bar and toolbar.
    public var isOmnibarVisible: Bool {
        visibility.isOmnibarVisible
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
        _ = setOmnibarVisible(!isOmnibarVisible)
        return isOmnibarVisible
    }
}
