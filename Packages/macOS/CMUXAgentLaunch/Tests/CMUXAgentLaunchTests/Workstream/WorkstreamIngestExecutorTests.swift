import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite("Workstream ingest executor")
struct WorkstreamIngestExecutorTests {
    @MainActor
    @Test("Ingest constructs items without occupying the UI thread")
    func itemConstructionLeavesMainThread() async {
        let store = WorkstreamStore(titleProvider: { _ in
            #expect(!Thread.isMainThread, "Feed item construction must run off the main thread")
            return "Tool"
        })
        await store.ingest(WorkstreamEvent(
            sessionId: "executor-regression",
            hookEventName: .userPromptSubmit,
            source: "claude",
            toolInputJSON: #"{"prompt":"Keep typing responsive"}"#
        ))
    }
}
