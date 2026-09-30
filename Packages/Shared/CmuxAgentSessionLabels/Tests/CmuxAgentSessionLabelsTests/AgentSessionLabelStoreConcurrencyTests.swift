import Foundation
import Testing

@testable import CmuxAgentSessionLabels

struct AgentSessionLabelStoreConcurrencyTests {
    private let now = Date(timeIntervalSince1970: 1_790_536_000)

    /// Two writers over one file keep both sets of labels.
    ///
    /// Actor isolation does not cover this: `inStateDirectory` hands out a new
    /// actor each call, and the named caller is a CLI, so the ordinary case is two
    /// processes. Without a lock across the read and the write, the second write
    /// drops the first one's record and both callers are told they succeeded.
    @Test func twoStoresOverOneFileKeepBothSetsOfLabels() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cmux-agent-session-labels-\(UUID().uuidString)")
            .appendingPathComponent("state")
        let first = AgentSessionLabelStore.inStateDirectory(directory)
        let second = AgentSessionLabelStore.inStateDirectory(directory)
        let rounds = 20

        // A throwing group, so a refused lock or a failed write is a failure here
        // rather than a missing record explained as a lost update.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for round in 0..<rounds {
                group.addTask {
                    try await first.setLabel(
                        "first \(round)",
                        for: try AgentSessionLabelKey(agent: "codex", sessionID: "s-\(round)"),
                        now: self.now
                    )
                }
                group.addTask {
                    try await second.setLabel(
                        "second \(round)",
                        for: try AgentSessionLabelKey(agent: "claude", sessionID: "s-\(round)"),
                        now: self.now
                    )
                }
            }
            try await group.waitForAll()
        }

        let labels = try await first.labels()
        #expect(labels.count == rounds * 2)
        for round in 0..<rounds {
            #expect(labels[try AgentSessionLabelKey(agent: "codex", sessionID: "s-\(round)")]?.text
                == "first \(round)")
            #expect(labels[try AgentSessionLabelKey(agent: "claude", sessionID: "s-\(round)")]?.text
                == "second \(round)")
        }
    }
}
