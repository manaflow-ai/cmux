public import AppKit

/// The application object that dispatches every event through an ``InputEventTap`` (the App's
/// `CmuxApplication`, whose `sendEvent` calls the tap's three delivery points).
@MainActor
public protocol InputEventTapHosting: AnyObject {
    /// The tap the application dispatches through; nil before the composition root sets it.
    var inputTap: InputEventTap? { get }
}

extension InputEventTap {
    /// The tap of the running application object: what UI kit owners that many packages construct
    /// (popups, overlays, tooltips, hover cards) subscribe to. It has the scope an AppKit local monitor
    /// had, every event `NSApplication.sendEvent` dispatches. Nil when the application object has no
    /// tap (a unit test host's plain `NSApplication`, or before the composition root set it), so those
    /// owners keep it as an injectable `() -> InputEventTap?` and resolve it when they subscribe.
    public static var application: InputEventTap? {
        (NSApp as? any InputEventTapHosting)?.inputTap
    }
}
