import AppKit
import CmuxNextDaemon
@testable import CmuxNextImportCards
@testable import CmuxNextImportSuggestions
import Foundation
import Testing

@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct AgentWorktreeImportTests {
    private func detection(hasConductor: Bool) throws -> ConductorImportDetection {
        let json = #"{"candidate_folders":{"codex":4},"has_conductor":\#(hasConductor),"card":{"id":"agents.conductor","kind":"conductor","name":"Agent worktrees","count":null}}"#
        return try JSONDecoder().decode(ConductorImportDetection.self, from: Data(json.utf8))
    }

    @Test func mergingDetectionPreservesKnownCountsAndOtherSources() throws {
        let local = ImportFinding(id: "agents.conductor", kind: .conductor, name: "Conductor", count: 7)
        let other = ImportFinding(id: "agents.codex", kind: .codex, name: "Codex", count: 20)
        let merged = ImportSuggestionsCenter.mergingAgentDetection(try detection(hasConductor: true), into: [other, local])
        #expect(merged.map(\.id) == [other.id, local.id])
        #expect(merged.last?.count == 7 && merged.last?.name == "Conductor")
        #expect(ImportSuggestionsCenter.mergingAgentDetection(nil, into: [local]) == [local])
    }

    @Test func genericCandidateOffersTheExistingExecutorWithoutAFalseCountOrIcon() throws {
        let findings = ImportSuggestionsCenter.mergingAgentDetection(try detection(hasConductor: false), into: [])
        let card = try #require(ImportCardDeck(findings: findings, state: .init(), jobs: .init(),
                                             apps: ["agents.conductor": "com.conductor.app"]).cards().first)
        #expect(card.id == "agents.conductor" && card.kind == .conductor)
        #expect(card.primary?.action == .start)
        #expect(card.facts == ImportSuggestionStrings.agentWorktrees)
        #expect(card.app == nil)
        #expect(card.title == ImportSuggestionStrings.agentWorktreesTitle)
    }

    @Test func genericWorkspaceUsesTheSharedAdoptionLedger() async throws {
        _ = NSApplication.shared
        let json = """
        {"plan":{"cloud_shutdown":"","has_conductor":false,"projects":[{
          "repo_id":"agent-repo:/src/app","name":"app","path":"/src/app",
          "worktreeinclude":[],"env_names":[],"workspaces":[{
            "id":"agent-worktree:/trees/task","name":"task","branch":"task","path":"/trees/task",
            "disposition":{"kind":"adopt"},"checked":true}]}],"cleanup":[],"warnings":[]}}
        """
        let reply = try JSONDecoder().decode(ConductorImportReply.self, from: Data(json.utf8))
        let daemon = ConductorImportRunTests.Daemon(reply)
        let host = ConductorImportRunTests.Host()
        let opened = try await ConductorImport(host: host, daemon: { daemon }, confirm: { plan in
            #expect(!plan.hasConductor)
            #expect(!ConductorImport.previewLines(plan).contains(ConductorImportStrings.deadline))
            return true
        }).run()
        #expect(opened == 1)
        #expect(host.opened == ["/trees/task"])
        #expect(daemon.records.map(\.workspace) == ["agent-worktree:/trees/task", "agent-worktree:/trees/task"])
        #expect(daemon.records.map(\.stage) == [.pending, .done])
    }

    @Test func aWarningOnlyPlanStillShowsItsPreviewAndNoShutdownDate() async throws {
        _ = NSApplication.shared
        let json = #"{"plan":{"cloud_shutdown":"","has_conductor":false,"projects":[],"cleanup":[],"warnings":[{"code":"agent-source-scan-failed","detail":"Agent source scan exceeded its folder limit."}]}}"#
        let reply = try JSONDecoder().decode(ConductorImportReply.self, from: Data(json.utf8))
        let daemon = ConductorImportRunTests.Daemon(reply)
        let host = ConductorImportRunTests.Host()
        var shown = false
        let result = try await ConductorImport(host: host, daemon: { daemon }, confirm: { plan in
            shown = true
            let lines = ConductorImport.previewLines(plan)
            #expect(lines.contains("Agent source scan exceeded its folder limit."))
            #expect(!lines.contains(ConductorImportStrings.deadline))
            return false
        }).run()
        #expect(shown && result == nil)
        #expect(host.opened.isEmpty && daemon.records.isEmpty)
    }

    @Test func relayCompletionDuringInitialScanRefreshesOnce() async throws {
        let suite = "agent-import-relay-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let center = ImportSuggestionsCenter(defaults: defaults,
            ledgerURL: FileManager.default.temporaryDirectory.appending(path: suite))
        center.host = ImportCardsHost(runImport: { _, _, _ in throw CancellationError() }, importedProfiles: { [] },
                                      openSettings: { _ in }, importClassic: { _ in nil }, importConductor: { _ in nil })
        let events = AsyncStream<Int>.makeStream()
        var releaseFirst: CheckedContinuation<Void, Never>?
        var scans = 0
        let finding = ImportFinding(id: "agents.conductor", kind: .conductor, name: "Agent worktrees", hasConductor: false)
        center.scanThisMac = { _ in
            scans += 1
            if scans == 1 {
                await withCheckedContinuation { continuation in
                    releaseFirst = continuation
                    events.continuation.yield(1)
                }
                return []
            }
            events.continuation.yield(scans)
            return [finding]
        }
        var iterator = events.stream.makeAsyncIterator()
        center.scan()
        #expect(await iterator.next() == 1)
        center.initialProjectRelayFinished()
        center.initialProjectRelayFinished()
        releaseFirst?.resume()
        #expect(await iterator.next() == 2)
        #expect(scans == 2)
        #expect(center.findings == [finding])
        events.continuation.finish()
    }
}
