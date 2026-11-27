@testable import CmuxNextUpdater
@testable import CmuxNextWebUpdates
import Foundation
import Testing

/// The app's `cas/1` fetch (WebUpdates+Cas.swift, RFD 0166): without the bundled CLI it is a miss
/// that names why (`last_fetch.cas_miss`), and a link that stops allowing the fetch midway cancels
/// it, as the archive's download does.
@Suite(.serialized) @MainActor struct WebUpdatesCasTests {
    static let request = WebUpdater.CasRequest(
        manifest: "m.json", pack: "p.pack", base: URL(string: "https://files.cmux.com/cas/1/")!, have: [],
        chunks: URL(filePath: "/tmp/chunks"), out: URL(filePath: "/tmp/out"), allowsConstrained: false, allowsExpensive: true)

    /// Waits until cancelled.
    nonisolated static func untilCancelled() async {
        for await _ in AsyncStream<Never>(Never.self, { _ in }) {}
    }

    @Test func withoutTheBundledCLIAFetchIsAMissThatSaysSo() async {
        let fetch = WebUpdates().casFetcher()
        #expect(await fetch(Self.request) == .failure(.init("no bundled cmux CLI")))
    }

    @Test func withoutTheBundledCLITheArchiveIsTakenAndTheMissRecorded() async throws {
        let root = try WebUpdateStoreTests.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let (server, _, updater, pointer) = try await WebUpdaterTests.casSetup(root)
        updater.casFetch = WebUpdates().casFetcher()
        await updater.check()
        #expect(server.downloads == 1)
        #expect(updater.state.active == pointer)
        #expect(updater.lastFetch?.by == .archive)
        #expect(updater.lastFetch?.casMiss == "no bundled cmux CLI")
    }

    @Test func aLinkLostMidFetchCancelsTheFetch() async {
        let ended = await WebUpdates.runWhileLinkAllows(Self.request, lost: { _ in }) { () -> Bool in
            await Self.untilCancelled()
            return Task.isCancelled
        }
        guard case .linkLost = ended else { Issue.record("expected linkLost, got \(ended)"); return }
    }

    @Test func aFetchThatEndsFirstStopsTheLinkWatch() async {
        let ended = await WebUpdates.runWhileLinkAllows(Self.request, lost: { _ in await Self.untilCancelled() }) { 7 }
        guard case .ran(let value) = ended else { Issue.record("expected ran, got \(ended)"); return }
        #expect(value == 7)
    }
}
