@testable import CmuxNextApp
import CmuxNextPages
import CmuxNextSettings
import CmuxNextUpdater
import Foundation
import Testing

/// R114 changelog page: verified notes only, newest first, and a "Try it" only
/// for an action in the compiled-in allow-list.
@MainActor
struct ChangelogPageProviderTests {
    private struct Source: ChangelogSource {
        var entries: [ReleaseNotesIndexEntry]
        var all: [String: ReleaseNotes]
        func index() async -> [ReleaseNotesIndexEntry] { entries }
        func notes(for build: String) async -> ReleaseNotes? { all[build] }
    }

    private func notes(_ build: String, action: String?) -> ReleaseNotes {
        ReleaseNotes(version: 1, build: build, shortVersion: "1.0.0-nightly.\(build)", date: "2026-10-04",
                     highlights: [.init(id: "h", title: "Hello", body: "Body", media: [],
                                        action: action.map { .init(id: $0, title: "Try it") })],
                     changes: ["a change"])
    }

    private let context = PageCallContext(page: PageDescriptor.changelog.id)

    @Test func listReturnsTheIndexAndTheRunningBuild() async throws {
        let source = Source(entries: [.init(build: "9", shortVersion: "1.0.0-nightly.9", date: "2026-10-04", highlights: 1)], all: [:])
        let value = try await ChangelogPageProvider(source: source, currentBuild: "9").call("cmux.changelog.list", params: .object([:]), context: context)
        #expect(value["current"]?.stringValue == "9")
        #expect(value["builds"]?.arrayValue?.first?["build"]?.stringValue == "9")
    }

    @Test func getKeepsOnlyAllowListedActions() async throws {
        let source = Source(entries: [], all: ["9": notes("9", action: "palette.checkForUpdates"), "8": notes("8", action: "quitEndEverything")])
        let provider = ChangelogPageProvider(source: source, currentBuild: "9")
        let allowed = try await provider.call("cmux.changelog.get", params: ["build": "9"], context: context)
        #expect(allowed["highlights"]?.arrayValue?.first?["action"]?["id"]?.stringValue == "palette.checkForUpdates")
        let refused = try await provider.call("cmux.changelog.get", params: ["build": "8"], context: context)
        #expect(refused["highlights"]?.arrayValue?.first?["action"] == nil)
        #expect(refused["changes"]?.arrayValue?.count == 1)
    }

    @Test func missingNotesAndBadParamsAreErrors() async throws {
        let provider = ChangelogPageProvider(source: Source(entries: [], all: [:]), currentBuild: "9")
        await #expect(throws: PageError.self) { try await provider.call("cmux.changelog.get", params: ["build": "9"], context: context) }
        await #expect(throws: PageError.self) { try await provider.call("cmux.changelog.get", params: .object([:]), context: context) }
        await #expect(throws: PageError.self) { try await provider.call("cmux.changelog.delete", params: .object([:]), context: context) }
    }

    @Test func thePageMayRunOnlyTheAllowList() {
        let page = PageDescriptor.changelog
        #expect(page.actions == PageDescriptor.changelogTryItActions)
        #expect(!page.actions.contains("quitEndEverything"))
        #expect(page.admits("cmux.changelog.get"))
        #expect(!page.admits("cmux.settings.set"))
    }
}
