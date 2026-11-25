import CmuxNextActions
@testable import CmuxNextControl
import Observation
import Testing

/// The bridge caches the control catalog (GPU audit 2026-10-21, offender 3).
/// Each input the catalog reads refreshes it, the published catalog always
/// equals a fresh build, and app state that only reasons read re-reads the
/// reasons without rebuilding the per-action info.
@MainActor
@Suite struct RegistryControlBridgeCacheTests {
    /// App state an unavailable reason reads (the sidebar document, daemon capabilities).
    @MainActor @Observable final class AppState {
        var blocked = false
        var workspaces = 1
    }

    @MainActor
    struct Fixture {
        let registry = ActionRegistry.standard()
        let bridge: RegistryControlBridge
        let router: ControlRouter

        init() {
            bridge = RegistryControlBridge(registry: registry)
            router = ControlRouter(identity: testIdentity(), executor: bridge, configuration: .loadTolerant)
        }

        /// Lets the queued observation and refresh tasks run.
        func settle(until done: () -> Bool = { false }) async {
            for _ in 0..<100 where !done() { await Task.yield() }
        }

        /// The published catalog is what a full build gives now.
        func expectCurrent(sourceLocation: SourceLocation = #_sourceLocation) {
            let fresh = RegistryControlBridge.catalog(from: registry)
            #expect(router.catalog.actions == fresh.actions, sourceLocation: sourceLocation)
            #expect(router.catalog.contextMask == fresh.contextMask, sourceLocation: sourceLocation)
        }
    }

    @Test func bindingRefreshesTheCatalog() async {
        let fixture = Fixture()
        fixture.bridge.attach(to: fixture.router)
        defer { fixture.bridge.detach() }
        #expect(fixture.router.catalog.resolve("splitRight")?.isBound == false)

        fixture.registry.bind("splitRight") {}
        await fixture.settle { fixture.router.catalog.resolve("splitRight")?.isBound == true }
        #expect(fixture.router.catalog.resolve("splitRight")?.isBound == true)
        fixture.expectCurrent()
    }

    @Test func adHocActionRefreshesTheCatalog() async {
        let fixture = Fixture()
        fixture.bridge.attach(to: fixture.router)
        defer { fixture.bridge.detach() }

        fixture.registry.register(Action(id: "test.adHoc", title: "Ad Hoc", handler: {}))
        await fixture.settle { fixture.router.catalog.resolve("test.adHoc") != nil }
        #expect(fixture.router.catalog.resolve("test.adHoc")?.isBound == true)
        fixture.expectCurrent()
    }

    @Test func seededDescriptorRefreshesTheCatalog() async {
        let fixture = Fixture()
        fixture.bridge.attach(to: fixture.router)
        defer { fixture.bridge.detach() }

        fixture.registry.seed([ActionDescriptor(id: "test.seeded", title: "Seeded", category: .window)])
        await fixture.settle { fixture.router.catalog.resolve("test.seeded") != nil }
        #expect(fixture.router.catalog.resolve("test.seeded")?.title == "Seeded")
        fixture.expectCurrent()
    }

    @Test func shortcutOverrideRefreshesTheShortcutText() async {
        let fixture = Fixture()
        fixture.bridge.attach(to: fixture.router)
        defer { fixture.bridge.detach() }
        let before = fixture.router.catalog.resolve("splitRight")?.shortcut

        fixture.registry.setShortcutOverride(Shortcut("\\", modifiers: [.command]), for: "splitRight")
        await fixture.settle { fixture.router.catalog.resolve("splitRight")?.shortcut == "⌘\\" }
        #expect(fixture.router.catalog.resolve("splitRight")?.shortcut == "⌘\\")
        #expect(fixture.router.catalog.resolve("splitRight")?.shortcutConfig == "cmd+\\")
        fixture.expectCurrent()

        fixture.registry.removeShortcutOverride(for: "splitRight")
        await fixture.settle { fixture.router.catalog.resolve("splitRight")?.shortcut == before }
        #expect(fixture.router.catalog.resolve("splitRight")?.shortcut == before)
        fixture.expectCurrent()
    }

    @Test func chordOverrideRefreshesTheShortcutText() async {
        let fixture = Fixture()
        fixture.bridge.attach(to: fixture.router)
        defer { fixture.bridge.detach() }

        fixture.registry.setChordOverride(ShortcutChord(Shortcut("b", modifiers: [.control]), Shortcut("c", modifiers: [])), for: "splitRight")
        let expected = fixture.registry.shortcutDisplay(for: "splitRight")
        await fixture.settle { fixture.router.catalog.resolve("splitRight")?.shortcut == expected }
        #expect(expected != nil)
        #expect(fixture.router.catalog.resolve("splitRight")?.shortcut == expected)
        #expect(fixture.router.catalog.resolve("splitRight")?.shortcutConfig == nil)
        fixture.expectCurrent()
    }

    @Test func disabledFeaturesRefreshTheCatalog() async throws {
        let fixture = Fixture()
        fixture.bridge.attach(to: fixture.router)
        defer { fixture.bridge.detach() }
        let cloud = try #require(fixture.registry.descriptors.first { ActionFeature.feature(of: $0) == .cloud })
        #expect(fixture.router.catalog.resolve(cloud.id.rawValue)?.disabledFeature == nil)

        fixture.registry.disabledFeatures = [.cloud]
        await fixture.settle { fixture.router.catalog.resolve(cloud.id.rawValue)?.disabledFeature != nil }
        #expect(fixture.router.catalog.resolve(cloud.id.rawValue)?.disabledFeature == ActionFeature.cloud.rawValue)
        fixture.expectCurrent()
    }

    @Test func reasonChangeRefreshesOnlyTheReasons() async {
        let fixture = Fixture()
        let state = AppState()
        fixture.registry.bind("splitRight", unavailable: { state.blocked ? "blocked" : nil }, invoke: { _ in })
        fixture.bridge.attach(to: fixture.router)
        defer { fixture.bridge.detach() }
        let builds = fixture.bridge.structureBuilds

        state.blocked = true
        await fixture.settle { fixture.router.catalog.resolve("splitRight")?.unavailableReason == "blocked" }
        #expect(fixture.router.catalog.resolve("splitRight")?.unavailableReason == "blocked")
        fixture.expectCurrent()

        state.blocked = false
        await fixture.settle { fixture.router.catalog.resolve("splitRight")?.unavailableReason == nil }
        #expect(fixture.router.catalog.resolve("splitRight")?.unavailableReason == nil)
        fixture.expectCurrent()
        #expect(fixture.bridge.structureBuilds == builds)
    }

    /// A new workspace moves state some reasons read without changing any
    /// reason: nothing is rebuilt and nothing is published.
    @Test func stateChangeThatKeepsEveryReasonPublishesNothing() async {
        let fixture = Fixture()
        let state = AppState()
        fixture.registry.bind("splitRight", unavailable: { state.workspaces > 0 ? nil : "no workspace" }, invoke: { _ in })
        fixture.bridge.attach(to: fixture.router)
        defer { fixture.bridge.detach() }
        let (builds, generation) = (fixture.bridge.structureBuilds, fixture.router.snapshots.current.generation)
        let reads = fixture.bridge.reasonReads

        for _ in 0..<5 { state.workspaces += 1 }
        // Wait for the re-read itself, so the checks below see it done.
        await fixture.settle { fixture.bridge.reasonReads > reads }
        #expect(fixture.bridge.reasonReads == reads + 1)
        #expect(fixture.bridge.structureBuilds == builds)
        #expect(fixture.router.snapshots.current.generation == generation)
        fixture.expectCurrent()

        // The reason observation is still armed after those refreshes.
        state.workspaces = 0
        await fixture.settle { fixture.router.catalog.resolve("splitRight")?.unavailableReason != nil }
        #expect(fixture.router.catalog.resolve("splitRight")?.unavailableReason == "no workspace")
    }

    /// SWITCH STALL (cmux22, macOS 27, 60 Hz): each workspace switch fired the one reason observation,
    /// which re-read every action's reason (4.6-5 ms) and rebuilt the published catalog (3.5 ms) on the
    /// main thread inside the switch's stall. A change re-reads only the reasons of the actions that read
    /// it, and the published catalog stays equal to a fresh build.
    @Test func aReasonChangeReadsOnlyTheReasonsThatReadIt() async {
        let fixture = Fixture()
        let state = AppState()
        var reads = ["splitRight": 0, "splitDown": 0]
        fixture.registry.bind("splitRight", unavailable: {
            reads["splitRight", default: 0] += 1
            return state.blocked ? "blocked" : nil
        }, invoke: { _ in })
        fixture.registry.bind("splitDown", unavailable: {
            reads["splitDown", default: 0] += 1
            return state.workspaces > 0 ? nil : "no workspace"
        }, invoke: { _ in })
        fixture.bridge.attach(to: fixture.router)
        defer { fixture.bridge.detach() }
        await fixture.settle()
        let before = reads

        state.blocked = true
        await fixture.settle { fixture.router.catalog.resolve("splitRight")?.unavailableReason == "blocked" }
        await fixture.settle()
        #expect(fixture.router.catalog.resolve("splitRight")?.unavailableReason == "blocked")
        #expect(reads["splitRight"] == (before["splitRight"] ?? 0) + 1, "splitRight's reason was read \(reads) (before \(before))")
        #expect(reads["splitDown"] == before["splitDown"], "a change that splitDown's reason does not read re-read it: \(reads) (before \(before))")

        state.workspaces = 0
        await fixture.settle { fixture.router.catalog.resolve("splitDown")?.unavailableReason == "no workspace" }
        await fixture.settle()
        #expect(reads["splitRight"] == (before["splitRight"] ?? 0) + 1, "a change that splitRight's reason does not read re-read it: \(reads)")
        #expect(reads["splitDown"] == (before["splitDown"] ?? 0) + 1)
        fixture.expectCurrent()
    }

    /// A binding that replaces an action's reason (the ids stay the same) publishes the new reason.
    @Test func rebindingAnActionPublishesItsNewReason() async {
        let fixture = Fixture()
        fixture.registry.bind("splitRight", unavailable: { nil }, invoke: { _ in })
        fixture.bridge.attach(to: fixture.router)
        defer { fixture.bridge.detach() }
        #expect(fixture.router.catalog.resolve("splitRight")?.unavailableReason == nil)

        fixture.registry.bind("splitRight", unavailable: { "rebound" }, invoke: { _ in })
        await fixture.settle { fixture.router.catalog.resolve("splitRight")?.unavailableReason == "rebound" }
        #expect(fixture.router.catalog.resolve("splitRight")?.unavailableReason == "rebound")
        fixture.expectCurrent()
    }

    /// A shortcut edit rebuilds the structure but keeps the live reason
    /// observations instead of arming others next to them: after many such
    /// edits, one binding change fires each action's reason observation once,
    /// not once per edit.
    @Test func structureRebuildsKeepOneReasonObservation() async {
        let fixture = Fixture()
        fixture.registry.bind("splitDown") {}
        fixture.bridge.attach(to: fixture.router)
        defer { fixture.bridge.detach() }
        let reads = fixture.bridge.reasonReads

        for key in ["1", "2", "3", "4", "5"] {
            let builds = fixture.bridge.structureBuilds
            fixture.registry.setShortcutOverride(Shortcut(key, modifiers: [.command, .option, .control]), for: "splitRight")
            await fixture.settle { fixture.bridge.structureBuilds > builds }
            fixture.expectCurrent()
        }
        #expect(fixture.bridge.reasonReads == reads)

        let firings = fixture.bridge.reasonFirings
        fixture.registry.bind("splitRight") {}
        await fixture.settle { fixture.router.catalog.resolve("splitRight")?.isBound == true && fixture.bridge.reasonReads > reads }
        await fixture.settle()
        #expect(fixture.bridge.reasonFirings == firings + fixture.router.catalog.actions.count)
        fixture.expectCurrent()
    }

    @Test func contextChangeUpdatesTheMaskWithoutARebuild() async {
        let fixture = Fixture()
        fixture.bridge.attach(to: fixture.router)
        defer { fixture.bridge.detach() }
        let builds = fixture.bridge.structureBuilds

        fixture.registry.context = [.browserFocused]
        await fixture.settle { fixture.router.catalog.contextMask == ActionContext.browserFocused.rawValue }
        #expect(fixture.router.catalog.contextMask == ActionContext.browserFocused.rawValue)
        #expect(fixture.bridge.structureBuilds == builds)
        fixture.expectCurrent()
    }

    @Test func changesInOneTurnCoalesceIntoOneBuild() async {
        let fixture = Fixture()
        fixture.bridge.attach(to: fixture.router)
        defer { fixture.bridge.detach() }
        let builds = fixture.bridge.structureBuilds

        fixture.registry.bind("splitRight") {}
        fixture.registry.bind("splitDown") {}
        fixture.registry.setShortcutOverride(Shortcut("\\", modifiers: [.command]), for: "splitRight")
        fixture.registry.disabledFeatures = [.cloud]
        await fixture.settle { fixture.bridge.structureBuilds > builds }
        await fixture.settle()
        #expect(fixture.bridge.structureBuilds == builds + 1)
        fixture.expectCurrent()
    }

    @Test func detachStopsRefreshesAndAttachCatchesUp() async {
        let fixture = Fixture()
        fixture.bridge.attach(to: fixture.router)
        fixture.bridge.detach()
        let builds = fixture.bridge.structureBuilds

        fixture.registry.bind("splitRight") {}
        await fixture.settle()
        #expect(fixture.bridge.structureBuilds == builds)
        #expect(fixture.router.catalog.resolve("splitRight")?.isBound == false)

        fixture.bridge.attach(to: fixture.router)
        defer { fixture.bridge.detach() }
        #expect(fixture.router.catalog.resolve("splitRight")?.isBound == true)
        fixture.expectCurrent()

        // Work already queued when detach runs does nothing.
        let queued = fixture.bridge.structureBuilds
        fixture.registry.bind("splitDown") {}
        fixture.bridge.detach()
        await fixture.settle()
        #expect(fixture.bridge.structureBuilds == queued)
        fixture.bridge.attach(to: fixture.router)
        #expect(fixture.router.catalog.resolve("splitDown")?.isBound == true)
        fixture.expectCurrent()

        // One observation chain after re-attaching: a change builds once.
        let reattached = fixture.bridge.structureBuilds
        fixture.registry.unbind("splitDown")
        await fixture.settle { fixture.bridge.structureBuilds > reattached }
        await fixture.settle()
        #expect(fixture.bridge.structureBuilds == reattached + 1)
        fixture.expectCurrent()
    }
}
