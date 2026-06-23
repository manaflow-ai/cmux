import AppKit
import Foundation
import Testing

@testable import CmuxWindowing

@MainActor
@Suite("WindowStoreRegistry")
struct WindowStoreRegistryTests {
    /// A reference-type stand-in for the app's `TabManager` so the registry can
    /// key its reverse index on object identity, exactly as the app does.
    private final class FakeTabManager {}

    private typealias Registry = WindowStoreRegistry<
        FakeTabManager, String, String, String, String, String
    >

    private func makeId() -> WindowID { WindowID(UUID()) }

    @Test("rebindTabManager seeds the store and the reverse index")
    func rebindSeedsReverseIndex() {
        let registry = Registry()
        let id = makeId()
        let manager = FakeTabManager()

        registry.rebindTabManager(manager, for: id)

        #expect(registry.tabManagers.model(for: id) === manager)
        #expect(registry.windowId(forTabManager: manager) == id)
    }

    @Test("rebinding a window to a new manager drops the prior reverse entry")
    func rebindReplacesManager() {
        let registry = Registry()
        let id = makeId()
        let first = FakeTabManager()
        let second = FakeTabManager()

        registry.rebindTabManager(first, for: id)
        registry.rebindTabManager(second, for: id)

        #expect(registry.tabManagers.model(for: id) === second)
        #expect(registry.windowId(forTabManager: second) == id)
        // The displaced manager no longer resolves to a window.
        #expect(registry.windowId(forTabManager: first) == nil)
    }

    @Test("removeSlices drops every domain slice plus the reverse index")
    func removeSlicesClearsEverything() {
        let registry = Registry()
        let id = makeId()
        let manager = FakeTabManager()

        registry.rebindTabManager(manager, for: id)
        registry.focusControllers.setModel("focus", for: id)
        registry.configStores.setModel("config", for: id)
        registry.sidebarStates.setModel("sidebar", for: id)
        registry.sidebarSelectionStates.setModel("selection", for: id)
        registry.fileExplorerStates.setModel("files", for: id)

        let removed = registry.removeSlices(for: id)

        #expect(removed?.tabManager === manager)
        #expect(removed?.focusController == "focus")
        #expect(registry.tabManagers.model(for: id) == nil)
        #expect(registry.focusControllers.model(for: id) == nil)
        #expect(registry.configStores.model(for: id) == nil)
        #expect(registry.sidebarStates.model(for: id) == nil)
        #expect(registry.sidebarSelectionStates.model(for: id) == nil)
        #expect(registry.fileExplorerStates.model(for: id) == nil)
        #expect(registry.windowId(forTabManager: manager) == nil)
    }

    @Test("removeSlices is a no-op when the window has no tabs slice")
    func removeSlicesGuard() {
        let registry = Registry()
        #expect(registry.removeSlices(for: makeId()) == nil)
    }

    @Test("removeSlices leaves a sibling window's slices intact")
    func removeSlicesIsolatesWindows() {
        let registry = Registry()
        let a = makeId()
        let b = makeId()
        let managerA = FakeTabManager()
        let managerB = FakeTabManager()
        registry.rebindTabManager(managerA, for: a)
        registry.rebindTabManager(managerB, for: b)

        registry.removeSlices(for: a)

        #expect(registry.tabManagers.model(for: a) == nil)
        #expect(registry.tabManagers.model(for: b) === managerB)
        #expect(registry.windowId(forTabManager: managerB) == b)
    }

    @Test("lastCascadePoint round-trips and defaults to zero")
    func cascadePoint() {
        let registry = Registry()
        #expect(registry.lastCascadePoint == .zero)
        registry.lastCascadePoint = NSPoint(x: 12, y: 34)
        #expect(registry.lastCascadePoint == NSPoint(x: 12, y: 34))
    }
}
