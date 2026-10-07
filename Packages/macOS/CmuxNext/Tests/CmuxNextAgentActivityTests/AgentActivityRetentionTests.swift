import Foundation
import Testing
@testable import CmuxNextAgentActivity

@Suite("Agent activity retention")
struct AgentActivityRetentionTests {
    @Test("events expire after thirty days and frames after seven days")
    func retentionUsesInjectedClock() {
        let now = Date(timeIntervalSince1970: 100 * 86_400)
        let clock = TestAgentActivityClock(now: now)
        let planner = AgentActivityRetentionPlanner(clock: clock)
        let events = [
            AgentActivityStoredEvent(id: "old", at: now.addingTimeInterval(-31 * 86_400), frameBlobs: ["old-frame"]),
            AgentActivityStoredEvent(id: "recent", at: now.addingTimeInterval(-29 * 86_400), frameBlobs: ["recent-frame"]),
        ]
        let frames = [
            AgentActivityStoredFrame(blob: "old-frame", capturedAt: now.addingTimeInterval(-8 * 86_400)),
            AgentActivityStoredFrame(blob: "recent-frame", capturedAt: now.addingTimeInterval(-6 * 86_400)),
        ]

        let plan = planner.plan(events: events, frames: frames)

        #expect(plan.eventIDs == ["old"])
        #expect(plan.frameBlobs == ["old-frame"])
    }

    @Test("a thumbnail blob name never reaches outside the store")
    func blobNamesStayInsideTheStore() async throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let store = try AgentActivityStore(applicationSupportDirectory: support, clock: TestAgentActivityClock(now: Date()))
        let event = AgentActivityStoredEvent(id: "e", at: Date(), frameBlobs: [])
        for name in ["../escape", "a/b", ".hidden", ""] {
            await #expect(throws: (any Error).self) {
                try await store.append(event, thumbnail: (blob: name, data: Data([1]), capturedAt: Date()))
            }
        }
        #expect(!FileManager.default.fileExists(atPath: support.appendingPathComponent("cmux/cua/escape").path))
        let url = try await store.append(event, thumbnail: (blob: "abc123.png", data: Data([1]), capturedAt: Date()))
        #expect(url?.lastPathComponent == "abc123.png")
    }
}

private struct TestAgentActivityClock: AgentActivityClock {
    let now: Date
}
