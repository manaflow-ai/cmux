import CmuxNextDesign
import CmuxNextPages
import Observation
import Testing

@MainActor
struct SettingsRefinedLookTests {
    @Test func defaultIsOffInPagesRegistry() throws {
        let store = TunableStore()
        store.register(PageTunables.all)
        let tunable = PageTunables.settingsRefinedLook
        let descriptor = try #require(store.descriptor(for: "settings.refinedLook"))
        #expect(descriptor.section == PageTunables.section)
        #expect(descriptor.defaultValue == .bool(false))
        #expect(tunable.value(in: store) == false)
        // A stable build never activates the store, even if an override was written.
        store.set(tunable.key, .bool(true))
        #expect(tunable.value(in: store) == false)
    }

    @Test func overrideAndResetUseTheExistingStore() {
        let store = TunableStore()
        store.register(PageTunables.all)
        store.activate(file: nil)
        let tunable = PageTunables.settingsRefinedLook
        #expect(tunable.value(in: store) == false)
        store.set(tunable.key, .bool(true))
        #expect(tunable.value(in: store) == true)
        #expect(store.set(tunable.key, .choice("refined")) == nil)
        #expect(tunable.value(in: store) == true)
        store.set(tunable.key, nil)
        #expect(tunable.value(in: store) == false)
    }

    @Test func overrideNotifiesTheHostFactsObserver() async {
        let store = TunableStore()
        store.register(PageTunables.all)
        store.activate(file: nil)
        let tunable = PageTunables.settingsRefinedLook
        await withCheckedContinuation { (changed: CheckedContinuation<Void, Never>) in
            withObservationTracking {
                #expect(tunable.value(in: store) == false)
            } onChange: {
                changed.resume()
            }
            store.set(tunable.key, .bool(true))
        }
        #expect(tunable.value(in: store) == true)
    }
}
