public import Foundation

/// The browser omnibar / address-bar focus lifecycle signals broadcast over
/// `NotificationCenter`.
///
/// Each case owns the exact notification name string the app target previously
/// declared inline on `extension Notification.Name`. The post sites
/// (`BrowserPanel`, `BrowserPanelView`, `Workspace`, `AppDelegate`,
/// `ContentView`) and the observe sites stay app-side; they reach the name
/// through the `Notification.Name.browser*` accessors the god still vends, which
/// now forward to `notificationName` here so each string lives in one place.
///
/// The wire shape is unchanged. The names are `"browserFocusAddressBar"`,
/// `"browserMoveOmnibarSelection"`, `"browserDidExitAddressBar"`, and
/// `"browserDidFocusAddressBar"`, posted with the browser panel id as `object`
/// (and, for `moveSelection`, a `["delta": Int]` `userInfo` payload assembled at
/// the post site).
public enum BrowserOmnibarFocusSignal: Sendable {
    /// A command to move keyboard focus into the browser address bar / omnibar.
    case focusAddressBar
    /// A request to move the omnibar suggestion selection by a delta.
    case moveSelection
    /// The address bar lost focus (the omnibar editing session ended).
    case didExitAddressBar
    /// The address bar gained focus (the omnibar editing session began).
    case didFocusAddressBar

    /// The `NotificationCenter` name for this signal.
    public var notificationName: Notification.Name {
        switch self {
        case .focusAddressBar:
            return Notification.Name("browserFocusAddressBar")
        case .moveSelection:
            return Notification.Name("browserMoveOmnibarSelection")
        case .didExitAddressBar:
            return Notification.Name("browserDidExitAddressBar")
        case .didFocusAddressBar:
            return Notification.Name("browserDidFocusAddressBar")
        }
    }
}
