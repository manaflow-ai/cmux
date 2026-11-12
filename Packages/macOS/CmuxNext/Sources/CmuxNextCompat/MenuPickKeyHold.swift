public import AppKit

/// Holds the keys typed right after a menu item was picked, until the item's action ran.
@MainActor
public final class MenuPickKeyHold {
    /// - Parameters:
    ///   - tracking: The app's menu tracking.
    ///   - replay: Sends a held key on, as `NSApplication.sendEvent` would.
    ///   - afterMenuAction: Runs its work once the picked item's action ran.
    public init(tracking: MenuTracking, replay: @escaping @MainActor (NSEvent) -> Void,
                afterMenuAction: @escaping @MainActor (@escaping @MainActor () -> Void) -> Void = { work in Task { @MainActor in work() } }) {}

    /// Takes `event` when a menu tracks; false when it goes on now.
    public func capture(_ event: NSEvent) -> Bool { false }
}
