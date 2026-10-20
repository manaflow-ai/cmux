public import CmuxNextDesign

/// Debug Settings of Back and Forward from the mouse and trackpad
/// (plans/cmux-next/history.md 4.2): on by default; the toggles let DEV and
/// NIGHTLY turn one off while it is new. Release and RC never activate the
/// store, so they keep the defaults.
public nonisolated struct NavigationTunables {
    public nonisolated init() {}
    public static let section = TunableSection(id: "navigation", title: "Back and Forward", symbol: "arrow.left.arrow.right", order: 47)

    /// Mouse buttons 4 and 5: Back and Forward (`MouseSideButtons`).
    public static let mouseSideButtons = Tunable<Bool>.toggle(
        "navigation.mouseSideButtons", section, "Mouse back and forward buttons",
        help: "Mouse buttons 4 and 5 go back and forward: in a browser page's history over a page, else Go Back and Go Forward.",
        default: true, code: "NavigationTunables.mouseSideButtons")

    /// A two-finger horizontal swipe over a Chromium page goes back or forward
    /// (`CEFSwipeNavigation`), while the system's "Swipe between pages" is on.
    public static let swipeNavigation = Tunable<Bool>.toggle(
        "browser.swipeNavigation", section, "Swipe between pages",
        help: "A two-finger horizontal swipe over a browser page goes back or forward when the page cannot scroll that way. Needs macOS's Swipe between pages.",
        default: true, code: "NavigationTunables.swipeNavigation")

    public static var all: [TunableDescriptor] { [mouseSideButtons.descriptor, swipeNavigation.descriptor] }
}
