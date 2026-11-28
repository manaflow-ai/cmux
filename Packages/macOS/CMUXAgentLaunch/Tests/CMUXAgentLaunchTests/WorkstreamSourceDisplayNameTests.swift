import CMUXAgentLaunch
import Testing

/// The Activity panel names the agent a reply goes to ("Send to Codex",
/// "Reply to Codex…"). It used to say Claude for every agent.
/// https://github.com/manaflow-ai/cmux/issues/49333
@Suite("WorkstreamSource display name")
struct WorkstreamSourceDisplayNameTests {
    @Test("Each source names its own agent")
    func eachSourceNamesItsOwnAgent() {
        #expect(WorkstreamSource.claude.displayName == "Claude")
        #expect(WorkstreamSource.codex.displayName == "Codex")
        #expect(WorkstreamSource.opencode.displayName == "OpenCode")
        #expect(WorkstreamSource.hermesAgent.displayName == "Hermes Agent")
        #expect(WorkstreamSource.codebuddy.displayName == "CodeBuddy")
    }

    @Test("Only the Claude source is called Claude")
    func onlyClaudeIsClaude() {
        for source in WorkstreamSource.allCases where source != .claude {
            #expect(!source.displayName.contains("Claude"), "\(source)")
            #expect(!source.displayName.isEmpty, "\(source)")
        }
    }
}

/// A hook agent `WorkstreamSource` doesn't list (Muse, Kimi, Kiro, ...) is
/// stored with the Claude fallback source and its own id in `sourceID`. Its
/// card must still carry its own name, not Claude's.
/// https://github.com/manaflow-ai/cmux/issues/49517
@MainActor
@Suite("WorkstreamItem agent display name")
struct WorkstreamItemAgentDisplayNameTests {
    private func ingestedStop(source: String) throws -> WorkstreamItem {
        let store = WorkstreamStore(ringCapacity: 10)
        store.ingest(WorkstreamEvent(
            sessionId: "agent-name", hookEventName: .stop, source: source
        ))
        return try #require(store.items.first)
    }

    @Test("A hook agent missing from the source list keeps its own name", arguments: [
        ("muse", "Muse Code"),
        ("kimi", "Kimi Code"),
        ("kiro", "Kiro"),
        ("antigravity", "Antigravity"),
        ("rovodev", "Rovo Dev"),
        ("omp", "OMP"),
        ("campfire", "Campfire"),
    ])
    func unlistedHookAgentKeepsItsName(source: String, name: String) throws {
        let item = try ingestedStop(source: source)
        #expect(item.sourceID == source)
        #expect(item.agentDisplayName == name)
    }

    @Test("An agent cmux has no name for shows the id it sent")
    func unknownAgentShowsItsID() throws {
        let item = try ingestedStop(source: "my-agent")
        #expect(item.agentDisplayName == "my-agent")
    }

    @Test("A listed source keeps the name its source gives", arguments: WorkstreamSource.allCases)
    func listedSourceKeepsItsName(source: WorkstreamSource) throws {
        let item = try ingestedStop(source: source.rawValue)
        #expect(item.sourceID == nil)
        #expect(item.agentDisplayName == source.displayName)
    }

    @Test("A stored row whose raw id is a listed source takes that source's name")
    func storedRowWithListedRawID() {
        let item = WorkstreamItem(
            workstreamId: "grok-session",
            source: .claude,
            sourceID: "grok",
            kind: .stop,
            payload: .stop(reason: nil)
        )
        #expect(item.agentDisplayName == "Grok")
    }
}
