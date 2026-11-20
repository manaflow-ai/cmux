# CmuxSidebar

Sidebar presentation, workspace models, and tip scheduling shared by the macOS app.

`SidebarTipsStore` is a SwiftUI `DynamicProperty` that owns tip persistence.
Construct it with the app's preferences domain and pass it to the button and
popover. Tests use an isolated domain; neither the store nor the schedule needs
an app launch.

Each manual opening advances to an unseen tip, then cycles through the catalog.
Automatic discovery offers at most one unseen tip per 24 hours. Once every tip
has been seen, it offers a rotating refresher after seven days without an
opening. Newly added tips use the daily cadence. The opt-out suppresses both
automatic cadences while leaving manual viewing available.

For example:

```swift
@MainActor
func example() {
    let name = "SidebarTipsExample.\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let store = SidebarTipsStore(defaults: defaults)
    store.open(tipIDs: ["split", "zoom"], now: Date(timeIntervalSince1970: 1_791_417_600))
    store.open(tipIDs: ["split", "zoom"], now: Date(timeIntervalSince1970: 1_791_417_605))
    assert(store.load().seenTipIDs == ["split", "zoom"])
}
```
