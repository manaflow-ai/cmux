public import AppKit

/// Holds the keys typed right after a menu item was picked, until the item's action ran.
///
/// AppKit blinks a picked item for about 300 ms and sends its action only after the menu's tracking ends. Keys
/// typed during the blink reach `NSApplication.sendEvent` at once, so they ran before the action: File > New Tab,
/// then "hello" typed at once, went to the old tab and left the new tab's field empty. While a menu tracks and is
/// open, it takes every key itself (type-select), so a key that reaches the app then was typed during a pick's
/// blink. This hold takes those keys and sends them on, in typing order, once the action ran: the New Tab action's
/// own hold then takes them for its field.
///
/// ```swift
/// let menuPickKeys = MenuPickKeyHold(tracking: MenuTracking()) { NSApp.sendEvent($0) }
/// // In the app's key-down path, before anything else takes the key:
/// if menuPickKeys.capture(event) { return true }
/// ```
///
/// Tests pass a ``MenuTracking`` on their own center and an `afterMenuAction` that runs when they say.
@MainActor
public final class MenuPickKeyHold {
    private let replay: @MainActor (NSEvent) -> Void
    private let afterMenuAction: @MainActor (@escaping @MainActor () -> Void) -> Void
    private let tracking: MenuTracking
    /// Menus tracking now (a pick's blink comes before its menu's end).
    private var openMenus = 0
    private var held: [NSEvent] = []

    /// - Parameters:
    ///   - tracking: The app's menu tracking; the hold follows its menus while it lives.
    ///   - replay: Sends a held key on, as `NSApplication.sendEvent` would (the app's key path, so a hold that the
    ///     picked item's action began takes it).
    ///   - afterMenuAction: Runs its work once the picked item's action ran. AppKit sends the action in the same
    ///     call that ends the tracking, so the default runs it on the main actor's next turn.
    public init(tracking: MenuTracking, replay: @escaping @MainActor (NSEvent) -> Void,
                afterMenuAction: @escaping @MainActor (@escaping @MainActor () -> Void) -> Void = { work in
                    // An ordering hop, not a wait: AppKit sends the picked item's action right after the tracking's end, in the same call.
                    Task { @MainActor in work() }
                }) {
        self.tracking = tracking
        self.replay = replay
        self.afterMenuAction = afterMenuAction
        tracking.subscribe { [weak self] change in self?.menuChanged(change) }
    }

    /// Takes `event` (a key-down) when a menu tracks, to send it on after the picked item's action; false when it
    /// goes on now. Costs one comparison when no menu tracks (it runs for every key-down).
    public func capture(_ event: NSEvent) -> Bool {
        guard openMenus > 0, event.type == .keyDown else { return false }
        held.append(event)
        return true
    }

    private func menuChanged(_ change: MenuTracking.Change) {
        switch change {
        case .began:
            openMenus += 1
        case .ended:
            openMenus = max(0, openMenus - 1)
            guard openMenus == 0, !held.isEmpty else { return }
            let keys = held
            held = []
            afterMenuAction { [replay] in keys.forEach(replay) }
        }
    }
}
