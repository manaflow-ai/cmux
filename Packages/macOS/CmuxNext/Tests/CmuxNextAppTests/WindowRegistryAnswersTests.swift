import CmuxNextCompat
import CmuxNextLayout
import Foundation
import Testing

/// NEW WORKSPACE 800 (#40839): `WindowRegistryStore` writes an observed per-workspace answer (the window kind in
/// `incognitoByWorkspace`, the owner in `ownerByWorkspace`) only where the answer changed, and compares against the
/// plain values it wrote last. The window kind decides whether a page may use a normal browser store
/// (`WindowManager.isIncognito(workspace:)`), so a stale entry there is a privacy defect, not a slow path.
///
/// Each test runs registry transitions through the store and, after EACH one, compares both observed maps with what
/// the registry itself says for every workspace id the test ever used (`expectAnswers`): the first window that lists a
/// workspace gives its owner and its kind, a discarded workspace is incognito with no owner unless a window lists
/// it, and every other id has no entry.
@MainActor @Suite struct WindowRegistryAnswersTests {
    /// Every workspace id these tests use.
    static let ids = ["a", "b", "c", "d", "z"]

    /// What `registry` says for each workspace, computed here without the store.
    private static func answers(of registry: WindowRegistry) -> (kinds: [String: Bool], owners: [String: String]) {
        var kinds: [String: Bool] = [:]
        var owners: [String: String] = [:]
        for window in registry.windows {
            for id in window.workspaceIDs where owners[id] == nil {
                owners[id] = window.id
                kinds[id] = registry.isIncognito(window.id)
            }
        }
        for id in registry.discarding { kinds[id] = true }
        return (kinds, owners)
    }

    /// Both observed maps of `store` equal its registry's answers for every id of `ids`, after `step`.
    private static func expectAnswers(_ store: WindowRegistryStore, after step: String) {
        let expected = answers(of: store.value)
        for id in ids {
            #expect(store.incognitoByWorkspace[id] == expected.kinds[id],
                    "after \(step): the kind of \(id) is \(String(describing: store.incognitoByWorkspace[id])), the registry says \(String(describing: expected.kinds[id]))")
            #expect(store.ownerByWorkspace[id] == expected.owners[id],
                    "after \(step): the owner of \(id) is \(store.ownerByWorkspace[id] ?? "nil"), the registry says \(expected.owners[id] ?? "nil")")
            #expect(store.owner(ofWorkspace: id) == store.value.owner(of: id), "after \(step): owner(ofWorkspace:) of \(id) differs from the registry")
        }
    }

    /// A normal window, an incognito window marked before it lists a workspace, a window that comes to the front, a
    /// refused move across the kinds, the incognito window's close (its workspace is discarded), the daemon's report
    /// that the discarded workspace is gone, and a normal window's close (it keeps its list).
    @Test func theAnswersFollowEachRegistryChange() throws {
        let store = WindowRegistryStore()
        store.apply { $0.openWindow(id: "w1", workspaceIDs: ["a", "b"]) }
        try #require(store.value.owner(of: "a") == "w1" && store.value.owner(of: "b") == "w1", "fixture: the window does not list a and b")
        Self.expectAnswers(store, after: "a normal window opened")
        #expect(store.incognitoByWorkspace["a"] == false)

        // Marked incognito before it lists anything (New Incognito Window): no answer changes yet.
        _ = store.takeMembershipWork()
        store.apply { $0.markIncognito("w2"); return WindowRegistry.Changes() }
        try #require(store.value.isIncognito("w2"), "fixture: the window is not marked incognito")
        Self.expectAnswers(store, after: "a window marked incognito before its list")
        #expect(store.takeMembershipWork().answerWrites == 0, "a mark with no listed workspace wrote an answer")

        store.apply { $0.openWindow(id: "w2", workspaceIDs: ["c"]) }
        try #require(store.value.owner(of: "c") == "w2", "fixture: the incognito window does not list c")
        Self.expectAnswers(store, after: "the incognito window listed c")
        #expect(store.incognitoByWorkspace["c"] == true)
        #expect(store.takeMembershipWork().answerWrites == 2, "one listed workspace did not write its own two answers")

        // A window that comes to the front changes the recency only.
        store.apply { $0.activate("w1"); return WindowRegistry.Changes() }
        Self.expectAnswers(store, after: "a window came to the front")
        #expect(store.takeMembershipWork().answerWrites == 0, "a window that came to the front wrote an answer")

        // Nothing moves across the kinds: the answers stay.
        store.apply { $0.move(["b"], to: "w2") }
        try #require(store.value.owner(of: "b") == "w1", "fixture: a normal workspace moved into the incognito window")
        Self.expectAnswers(store, after: "a refused move across the kinds")

        // The incognito window closes for good: its workspace is discarded, incognito with no owner.
        store.apply { $0.close("w2") }
        try #require(store.value.discarding.contains("c") && store.value.owner(of: "c") == nil, "fixture: c is not discarded")
        Self.expectAnswers(store, after: "the incognito window closed")
        #expect(store.incognitoByWorkspace["c"] == true)
        #expect(store.ownerByWorkspace["c"] == nil)

        // The daemon reports the discarded workspace gone: it has no answer any more.
        store.apply { $0.reconcile(live: ["a", "b"], dead: ["c"], fallbackWindow: "w1") }
        try #require(!store.value.discarding.contains("c"), "fixture: c is still discarded")
        Self.expectAnswers(store, after: "the discarded workspace was reported gone")
        #expect(store.incognitoByWorkspace["c"] == nil)

        // A workspace moves between two normal windows: its owner changes, its kind stays.
        store.apply { $0.openWindow(id: "w3", workspaceIDs: ["b"]) }
        try #require(store.value.owner(of: "b") == "w3", "fixture: b did not move to the new window")
        Self.expectAnswers(store, after: "a workspace moved to a new normal window")

        // A normal window closes and keeps its list: its workspace keeps its answers.
        store.apply { $0.close("w3") }
        try #require(store.value.window("w3")?.isOpen == false && store.value.owner(of: "b") == "w3", "fixture: the closed window lost its list")
        Self.expectAnswers(store, after: "a normal window closed with its list")
        #expect(store.incognitoByWorkspace["b"] == false)
    }

    /// A workspace discarded with no window (a crashed run's incognito workspace) is incognito with no owner; when
    /// the daemon stops reporting it, the answer goes.
    @Test func aDiscardedWorkspaceWithNoWindowIsIncognito() throws {
        let store = WindowRegistryStore()
        store.apply { $0.openWindow(id: "w1", workspaceIDs: ["a"]) }
        store.apply { $0.markDiscarding(["z"]); return WindowRegistry.Changes() }
        try #require(store.value.discarding.contains("z"), "fixture: z is not discarded")
        Self.expectAnswers(store, after: "a workspace was marked discarded")
        #expect(store.incognitoByWorkspace["z"] == true)
        #expect(store.ownerByWorkspace["z"] == nil)
        store.apply { $0.reconcile(live: ["a"], dead: [], fallbackWindow: "w1") }
        try #require(!store.value.discarding.contains("z"), "fixture: z is still discarded")
        Self.expectAnswers(store, after: "the daemon stopped reporting the discarded workspace")
        #expect(store.incognitoByWorkspace["z"] == nil)
    }

    /// A broken invariant (two windows list one workspace): the first window that lists it gives both answers, as
    /// `WindowRegistry.owner(of:)` does, whatever the kind of the second.
    @Test func theFirstWindowThatListsAWorkspaceAnswersForIt() throws {
        let store = WindowRegistryStore()
        store.apply { registry in
            registry = WindowRegistry(windows: [WindowRegistry.Window(id: "w1", workspaceIDs: ["d"]),
                                                WindowRegistry.Window(id: "w2", workspaceIDs: ["d", "a"])])
            registry.markIncognito("w2")
            return WindowRegistry.Changes()
        }
        try #require(store.value.owner(of: "d") == "w1" && store.value.isIncognito("w2"), "fixture: the registry does not list d two times")
        Self.expectAnswers(store, after: "two windows listed one workspace")
        #expect(store.incognitoByWorkspace["d"] == false)
        #expect(store.ownerByWorkspace["d"] == "w1")
        #expect(store.incognitoByWorkspace["a"] == true)
    }
}
