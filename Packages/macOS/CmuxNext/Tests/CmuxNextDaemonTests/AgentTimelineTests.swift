import Foundation
import Testing
@testable import CmuxNextDaemon

/// u3320 (Lawrence 2026-10-19): the workspace hover card lists each prompt sent and when, when an
/// agent finished, and when it started waiting for the person. The roster notes those moments from
/// the agent statuses the daemon pushes, bounded, in memory.
struct AgentTimelineTests {
    private static let surface = SurfaceID(rawValue: 7)

    private static func status(_ state: AgentState, at ms: UInt64, prompt: String? = nil, source: String = "hook") -> AgentStatus {
        AgentStatus(surface: surface, state: state, source: source, agent: "claude", updatedAtMs: ms, sinceMs: ms, lastPrompt: prompt)
    }

    @Test func aHookTurnNotesItsPromptItsWaitAndItsFinish() {
        var roster = AgentRoster()
        roster.apply(Self.status(.idle, at: 1_000))
        roster.apply(Self.status(.working, at: 2_000, prompt: "Fix the build"))
        roster.apply(Self.status(.blocked, at: 3_000, prompt: "Fix the build"))
        roster.apply(Self.status(.working, at: 4_000, prompt: "Fix the build"))
        roster.apply(Self.status(.idle, at: 5_000, prompt: "Fix the build"))
        roster.apply(Self.status(.working, at: 6_000, prompt: "Now run the tests"))
        let events = roster.timelines[Self.surface]?.events ?? []
        // The answer to the wait (working again, the same prompt) is no new prompt.
        #expect(events.map(\.kind) == [.prompt, .waiting, .finished, .prompt])
        #expect(events.map(\.atMs) == [2_000, 3_000, 5_000, 6_000])
        #expect(events.first?.text == "Fix the build")
        #expect(events.last?.text == "Now run the tests")
        #expect(events.allSatisfy { $0.agent == "claude" })
    }

    @Test func aReporterThatSaysWorkingThroughATurnNotesOneStart() {
        var roster = AgentRoster()
        roster.apply(Self.status(.working, at: 1_000, source: "detector"))
        roster.apply(Self.status(.working, at: 2_000, source: "detector"))
        roster.apply(Self.status(.done, at: 3_000, source: "detector"))
        #expect(roster.timelines[Self.surface]?.events.map(\.kind) == [.started, .finished])
    }

    @Test func aReconnectSeedOfTheSameStatusNotesNothingNew() {
        var roster = AgentRoster()
        let working = Self.status(.working, at: 2_000, prompt: "Fix the build")
        roster.seed([working])
        roster.seed([working])
        #expect(roster.timelines[Self.surface]?.events.count == 1)
    }

    @Test func aTimelineKeepsItsNewestEventsAndShortText() {
        var timeline = AgentTimeline()
        for index in 0..<(AgentTimeline.limit + 10) {
            timeline.append(AgentTimelineEvent(kind: .prompt, atMs: UInt64(index), text: String(repeating: "a", count: 1_000)))
        }
        #expect(timeline.events.count == AgentTimeline.limit)
        #expect(timeline.events.first?.atMs == 10)
        #expect(timeline.events.allSatisfy { ($0.text?.count ?? 0) <= AgentTimeline.textLimit })
        #expect(AgentTimeline.trimmedText("  two\n  lines ") == "two lines")
        #expect(AgentTimeline.trimmedText(" \n ") == nil)
    }

    @Test func theRosterKeepsATimelineForAtMostItsSurfaceLimit() {
        var roster = AgentRoster()
        for index in 0..<(AgentRoster.timelineSurfaceLimit + 5) {
            roster.apply(AgentStatus(surface: SurfaceID(rawValue: UInt64(index)), state: .working, source: "hook",
                                     updatedAtMs: UInt64(index + 1), sinceMs: UInt64(index + 1), lastPrompt: "p"))
        }
        #expect(roster.timelines.count == AgentRoster.timelineSurfaceLimit)
        // The quietest (oldest) terminals went first.
        #expect(roster.timelines[SurfaceID(rawValue: 0)] == nil)
        #expect(roster.timelines[SurfaceID(rawValue: UInt64(AgentRoster.timelineSurfaceLimit + 4))] != nil)
    }
}
