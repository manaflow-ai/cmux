public import AppKit

/// The Chief Settings popovers the Chief pet's Chief Pet Settings… can open: each Home view's
/// `ChiefPetSettingsRows`, held weakly while installed. One per app, owned by its services (no
/// process-wide registry), so two apps in one process (tests) never open each other's popovers.
@MainActor
public final class ChiefPetHomes {
    let live = NSHashTable<ChiefPetSettingsRows>.weakObjects()

    public init() {}

    /// Chief Pet Settings…: activates cmux (the pet never does; `noActivate`, for tests and captures,
    /// leaves it), then opens the Chief Settings popover over a Home on screen, frontmost window
    /// first (`NSApp.orderedWindows`: the pet is right-clicked while cmux is usually in the
    /// background, where no window is key or main), bringing that window forward. False when no
    /// Home on screen shows it.
    public func open(noActivate: Bool) -> Bool {
        if !noActivate { NSApp.activate() }
        let order = NSApp.orderedWindows
        func rank(_ rows: ChiefPetSettingsRows) -> Int { rows.host?.window.flatMap { w in order.firstIndex { $0 === w } } ?? order.count }
        return live.allObjects.sorted { rank($0) < rank($1) }.contains { $0.openOnScreen(noActivate: noActivate) }
    }
}
