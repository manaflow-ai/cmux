import Foundation
import Testing

@testable import CmuxWindowing

@MainActor
@Suite("WindowScopedStore")
struct WindowScopedStoreTests {
    private func makeId() -> WindowID { WindowID(UUID()) }

    @Test("setModel/model round-trips per window")
    func setAndGet() {
        let store = WindowScopedStore<String>()
        let a = makeId()
        let b = makeId()
        store.setModel("alpha", for: a)
        store.setModel("beta", for: b)
        #expect(store.model(for: a) == "alpha")
        #expect(store.model(for: b) == "beta")
        #expect(Set(store.models) == ["alpha", "beta"])
    }

    @Test("setModel replaces a prior model for the same window")
    func setReplaces() {
        let store = WindowScopedStore<String>()
        let a = makeId()
        store.setModel("first", for: a)
        store.setModel("second", for: a)
        #expect(store.model(for: a) == "second")
        #expect(store.models == ["second"])
    }

    @Test("remove drops and returns only that window's model, idempotently")
    func explicitRemove() {
        let store = WindowScopedStore<String>()
        let a = makeId()
        let b = makeId()
        store.setModel("alpha", for: a)
        store.setModel("beta", for: b)

        #expect(store.remove(a) == "alpha")
        #expect(store.model(for: a) == nil)
        // Sibling window's slice is untouched.
        #expect(store.model(for: b) == "beta")
        // Removing again is a no-op (the teardown paths can call it twice).
        #expect(store.remove(a) == nil)
    }
}
