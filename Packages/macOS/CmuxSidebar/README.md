# CmuxSidebar

Sidebar presentation, workspace models, and tip scheduling shared by the macOS app.

`SidebarTipsStore` is a SwiftUI `DynamicProperty` that owns tip persistence.
Construct it with the app's preferences domain and pass it to the button and
popover. Tests use an isolated domain; neither the store nor the schedule needs
an app launch:

```swift
@MainActor
func example() {
    let name = "SidebarTipsExample.\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let store = SidebarTipsStore(defaults: defaults)
    store.open(tipIDs: ["split", "zoom"], now: Date(timeIntervalSince1970: 1_791_417_600))
    store.select("zoom")
    assert(store.load().seenTipIDs == ["split", "zoom"])
}
```
