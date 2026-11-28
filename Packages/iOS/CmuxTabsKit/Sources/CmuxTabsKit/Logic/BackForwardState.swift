/// What the toolbar's back | forward capsule shows and accepts for a tab.
/// Platform neutral so the rules are unit-tested (the toolbar reads them).
struct BackForwardState: Equatable, Sendable {
    /// The back circle (or back | forward capsule) is on screen.
    var visible: Bool
    var backEnabled: Bool
    /// Forward history exists: the capsule splits and forward takes taps.
    var forwardShown: Bool

    /// `hasHistory`: the tab offers back/forward at all (a note or a
    /// terminal does not). `sidesVisible`: the bar is expanded (the
    /// collapsed pill hides the side controls).
    init(canGoBack: Bool, canGoForward: Bool, hasHistory: Bool, sidesVisible: Bool, editing: Bool) {
        visible = hasHistory && sidesVisible && !editing
        backEnabled = visible && canGoBack
        forwardShown = hasHistory && canGoForward
    }

    init(tab: TabsKitTab?, sidesVisible: Bool, editing: Bool) {
        self.init(canGoBack: tab?.navigation.canGoBack == true, canGoForward: tab?.navigation.canGoForward == true,
                  hasHistory: tab?.features.contains(.history) == true, sidesVisible: sidesVisible, editing: editing)
    }
}
