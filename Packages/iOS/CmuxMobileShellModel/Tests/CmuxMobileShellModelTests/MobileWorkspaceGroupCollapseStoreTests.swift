import Foundation
import Testing

@testable import CmuxMobileShellModel

/// Behavior tests for ``MobileWorkspaceGroupCollapseStore`` using a suite-scoped
/// `UserDefaults` so they never touch `UserDefaults.standard`.
///
/// The store's contract is that folder collapse is device-local: the Mac's value
/// only seeds a group the first time it is seen, after which this device's choice
/// wins and is never overridden by the Mac. That independence is the whole point
/// of the fix (collapsing on the phone must not collapse on the desktop), so these
/// tests pin it down.
@Suite struct MobileWorkspaceGroupCollapseStoreTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "MobileWorkspaceGroupCollapseStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func group(
        _ id: MobileWorkspaceGroupPreview.ID,
        collapsed: Bool
    ) -> MobileWorkspaceGroupPreview {
        MobileWorkspaceGroupPreview(
            id: id,
            name: id.rawValue,
            isCollapsed: collapsed,
            isPinned: false,
            anchorWorkspaceID: MobileWorkspacePreview.ID(rawValue: "anchor-\(id.rawValue)")
        )
    }

    @Test func seedsUnknownGroupsFromTheMacValue() {
        var store = MobileWorkspaceGroupCollapseStore(defaults: makeDefaults())
        let resolved = store.apply(to: [group("a", collapsed: true), group("b", collapsed: false)])
        #expect(resolved.first { $0.id == "a" }?.isCollapsed == true)
        #expect(resolved.first { $0.id == "b" }?.isCollapsed == false)
        // The seed is now device-owned.
        #expect(store.isCollapsed("a") == true)
        #expect(store.isCollapsed("b") == false)
    }

    @Test func localDecisionOverridesTheMacValue() {
        var store = MobileWorkspaceGroupCollapseStore(defaults: makeDefaults())
        _ = store.apply(to: [group("a", collapsed: false)]) // seed expanded
        store.set("a", collapsed: true) // collapse on this device
        // Mac still reports expanded; the device choice must win.
        let resolved = store.apply(to: [group("a", collapsed: false)])
        #expect(resolved.first { $0.id == "a" }?.isCollapsed == true)
    }

    @Test func macChangesNeverOverrideAfterFirstSight() {
        var store = MobileWorkspaceGroupCollapseStore(defaults: makeDefaults())
        _ = store.apply(to: [group("a", collapsed: false)]) // seed expanded, no local toggle
        // Mac collapses the group; the phone must NOT follow (independence).
        let resolved = store.apply(to: [group("a", collapsed: true)])
        #expect(resolved.first { $0.id == "a" }?.isCollapsed == false)
    }

    @Test func persistsAcrossInstances() {
        let defaults = makeDefaults()
        var store = MobileWorkspaceGroupCollapseStore(defaults: defaults)
        _ = store.apply(to: [group("a", collapsed: false)])
        store.set("a", collapsed: true)

        // A fresh store on the same defaults (app relaunch) reads the choice back.
        let reloaded = MobileWorkspaceGroupCollapseStore(defaults: defaults)
        #expect(reloaded.isCollapsed("a") == true)
    }

    @Test func prunesDecisionsForGroupsThatNoLongerExist() {
        let defaults = makeDefaults()
        var store = MobileWorkspaceGroupCollapseStore(defaults: defaults)
        _ = store.apply(to: [group("a", collapsed: true), group("b", collapsed: true)])
        #expect(store.isCollapsed("b") == true)

        // "b" is gone in the next list; its decision is dropped so the map stays
        // bounded by the live group count.
        _ = store.apply(to: [group("a", collapsed: true)])
        #expect(store.isCollapsed("b") == nil)
        #expect(store.isCollapsed("a") == true)

        let reloaded = MobileWorkspaceGroupCollapseStore(defaults: defaults)
        #expect(reloaded.isCollapsed("b") == nil)
    }
}
