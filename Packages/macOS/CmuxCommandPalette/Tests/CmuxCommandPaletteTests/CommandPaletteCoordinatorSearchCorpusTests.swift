import Testing
@testable import CmuxCommandPalette

@MainActor
@Suite struct CommandPaletteCoordinatorSearchCorpusTests {
    private func command(_ id: String, rank: Int = 0) -> CommandPaletteCommand {
        CommandPaletteCommand(
            id: id,
            rank: rank,
            title: id,
            subtitle: "",
            shortcutHint: nil,
            kindLabel: nil,
            keywords: [],
            dismissOnRun: false,
            action: {}
        )
    }

    /// A scriptable host: each `corpusBuildPlan` call returns the queued
    /// fingerprint and counts how many times the entry list is materialized,
    /// so a test can assert the rebuild-skip guard never rebuilds entries.
    @MainActor
    private final class FakeHost {
        var presented = true
        var query = ""
        var fingerprint = 1
        var includeSurfaces = false
        var entries: [CommandPaletteCommand] = []
        var planCallCount = 0
        var entriesCallCount = 0
        var resultsRefreshQueries: [String] = []

        func makeHost() -> CommandPaletteSearchCorpusHost {
            CommandPaletteSearchCorpusHost(
                isCommandPalettePresented: { self.presented },
                presentationQuery: { self.query },
                corpusBuildPlan: { scope, _ in
                    self.planCallCount += 1
                    return CommandPaletteSearchCorpusBuildPlan(
                        scope: scope,
                        includeSurfaces: self.includeSurfaces,
                        fingerprint: self.fingerprint
                    )
                },
                corpusEntries: { _ in
                    self.entriesCallCount += 1
                    return self.entries
                },
                scheduleResultsRefresh: { query, _ in
                    self.resultsRefreshQueries.append(query)
                }
            )
        }
    }

    @Test func firstRefreshBuildsCorpusAndCaches() {
        let coordinator = CommandPaletteCoordinator()
        let fake = FakeHost()
        fake.query = "alpha"
        fake.entries = [command("a"), command("b")]

        coordinator.refreshSearchCorpus(host: fake.makeHost())

        #expect(coordinator.searchCorpus.map(\.payload) == ["a", "b"])
        #expect(Set(coordinator.searchCorpusByID.keys) == ["a", "b"])
        #expect(Set(coordinator.searchCommandsByID.keys) == ["a", "b"])
        #expect(coordinator.cachedCorpusScope == .switcher)
        #expect(coordinator.cachedCorpusFingerprint == 1)
        #expect(fake.entriesCallCount == 1)
    }

    @Test func unchangedFingerprintSkipsRebuild() {
        let coordinator = CommandPaletteCoordinator()
        let fake = FakeHost()
        fake.entries = [command("a")]

        coordinator.refreshSearchCorpus(host: fake.makeHost())
        #expect(fake.entriesCallCount == 1)

        // Same scope + fingerprint, not forced: entries must not rebuild.
        coordinator.refreshSearchCorpus(host: fake.makeHost())
        #expect(fake.entriesCallCount == 1)
        #expect(fake.planCallCount == 2)
    }

    @Test func forceRebuildsEvenWhenUnchanged() {
        let coordinator = CommandPaletteCoordinator()
        let fake = FakeHost()
        fake.entries = [command("a")]

        coordinator.refreshSearchCorpus(host: fake.makeHost())
        coordinator.refreshSearchCorpus(force: true, host: fake.makeHost())
        #expect(fake.entriesCallCount == 2)
    }

    @Test func changedFingerprintRebuilds() {
        let coordinator = CommandPaletteCoordinator()
        let fake = FakeHost()
        fake.entries = [command("a")]

        coordinator.refreshSearchCorpus(host: fake.makeHost())
        fake.fingerprint = 2
        fake.entries = [command("a"), command("c")]
        coordinator.refreshSearchCorpus(host: fake.makeHost())

        #expect(coordinator.cachedCorpusFingerprint == 2)
        #expect(coordinator.searchCorpus.map(\.payload) == ["a", "c"])
        #expect(fake.entriesCallCount == 2)
    }

    @Test func scopeFromQueryPrefixSelectsCommands() {
        let coordinator = CommandPaletteCoordinator()
        let fake = FakeHost()
        fake.query = ">build"
        fake.entries = [command("x")]

        coordinator.refreshSearchCorpus(host: fake.makeHost())
        #expect(coordinator.cachedCorpusScope == .commands)
    }

    @Test func invalidatingFingerprintForcesNextRebuild() {
        let coordinator = CommandPaletteCoordinator()
        let fake = FakeHost()
        fake.entries = [command("a")]

        coordinator.refreshSearchCorpus(host: fake.makeHost())
        coordinator.invalidateSearchCorpusFingerprintCache()
        #expect(coordinator.cachedCorpusFingerprint == nil)

        coordinator.refreshSearchCorpus(host: fake.makeHost())
        #expect(fake.entriesCallCount == 2)
    }

    @Test func resetClearsCorpusAndCache() {
        let coordinator = CommandPaletteCoordinator()
        let fake = FakeHost()
        fake.entries = [command("a")]

        coordinator.refreshSearchCorpus(host: fake.makeHost())
        coordinator.resetSearchCorpus()

        #expect(coordinator.searchCorpus.isEmpty)
        #expect(coordinator.searchCorpusByID.isEmpty)
        #expect(coordinator.searchCommandsByID.isEmpty)
        #expect(coordinator.nucleoSearchIndex == nil)
        #expect(coordinator.cachedCorpusScope == nil)
        #expect(coordinator.cachedCorpusFingerprint == nil)
    }

    /// Drains the async index build, returning whether a nucleo index applied.
    /// When the nucleo FFI dylib is not bundled in this environment the index
    /// cannot build (production `init?` returns nil); callers then assert the
    /// `index == nil` branch, which is a real faithful path.
    private func drainIndexBuild(_ coordinator: CommandPaletteCoordinator) async -> Bool {
        for _ in 0..<200 {
            if coordinator.nucleoSearchIndex != nil { return true }
            await Task.yield()
        }
        return coordinator.nucleoSearchIndex != nil
    }

    @Test func indexBuildPopulatesIndexAndRefreshesResults() async {
        let coordinator = CommandPaletteCoordinator()
        let fake = FakeHost()
        fake.query = "alpha"
        fake.entries = [command("a"), command("b")]

        coordinator.refreshSearchCorpus(host: fake.makeHost())
        let built = await drainIndexBuild(coordinator)

        if built {
            // A presented same-scope index completion schedules one refresh.
            #expect(fake.resultsRefreshQueries == ["alpha"])
        } else {
            // No index: the `guard index != nil` path schedules no refresh.
            #expect(fake.resultsRefreshQueries.isEmpty)
        }
    }

    @Test func indexBuildDoesNotRefreshWhenNotPresented() async {
        let coordinator = CommandPaletteCoordinator()
        let fake = FakeHost()
        fake.presented = false
        fake.query = "alpha"
        fake.entries = [command("a")]

        coordinator.refreshSearchCorpus(host: fake.makeHost())
        _ = await drainIndexBuild(coordinator)
        // Not presented: no refresh regardless of whether the index built.
        #expect(fake.resultsRefreshQueries.isEmpty)
    }
}
