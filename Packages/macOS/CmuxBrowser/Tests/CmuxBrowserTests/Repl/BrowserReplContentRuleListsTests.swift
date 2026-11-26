import Foundation
import Testing
import WebKit
@testable import CmuxBrowser

/// A session's compiled domain-policy rule list lives in a persistent
/// WKContentRuleListStore; it must not outlive the session's rules.
@MainActor
@Suite struct BrowserReplContentRuleListsTests {
    private let rules: [Any] = [
        ["trigger": ["url-filter": "blocked\\.example"], "action": ["type": "block"]],
    ]

    private func temporaryStore() throws -> (WKContentRuleListStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-rule-lists-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try #require(WKContentRuleListStore(url: directory))
        return (store, directory)
    }

    private func identifiers(in store: WKContentRuleListStore) async -> [String] {
        await withCheckedContinuation { continuation in
            store.getAvailableContentRuleListIdentifiers { continuation.resume(returning: $0 ?? []) }
        }
    }

    @Test func compiledRulesAreStoredUnderTheSessionIdentifier() async throws {
        let (store, directory) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lists = BrowserReplContentRuleLists(sessionID: "one shot/1", store: store)
        #expect(lists.identifier == "cmux.browser-repl.one_shot_1")
        let list = try await lists.update(rules: rules)
        #expect(list != nil)
        #expect(await identifiers(in: store) == [lists.identifier])
    }

    @Test func clearingTheRulesRemovesTheCompiledList() async throws {
        let (store, directory) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lists = BrowserReplContentRuleLists(sessionID: "session", store: store)
        _ = try await lists.update(rules: rules)
        #expect(try await lists.update(rules: nil) == nil)
        #expect(await identifiers(in: store).isEmpty)
    }

    @Test func clearingNeverCompiledRulesIsQuiet() async throws {
        let (store, directory) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lists = BrowserReplContentRuleLists(sessionID: "session", store: store)
        #expect(try await lists.update(rules: []) == nil)
        #expect(await identifiers(in: store).isEmpty)
    }

    @Test func rulesThatDoNotCompileFailAsInvalid() async throws {
        let (store, directory) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lists = BrowserReplContentRuleLists(sessionID: "session", store: store)
        await #expect(throws: BrowserReplDriverError.self) {
            _ = try await lists.update(rules: [["trigger": [:], "action": ["type": "block"]]])
        }
    }
}
