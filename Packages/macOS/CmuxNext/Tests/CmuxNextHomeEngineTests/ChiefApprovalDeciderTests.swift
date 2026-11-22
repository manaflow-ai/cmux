import Foundation
@testable import CmuxNextHomeEngine
import Testing

@MainActor @Suite struct ChiefApprovalDeciderTests {
    @Test func anUnavailableDaemonLeavesTheCardRetryable() async {
        let home = ChiefHome(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), isolated: true)
        await confirmation("Both candidate homes are resolved", expectedCount: 2) { resolved in
            let decider = ChiefApprovalDecider(home: home, app: nil, work: .init(), environment: { _ in
                resolved()
                return nil
            })
            let result = await decider.decide(
                .init(chief: "agent_mux", session: "local/approval-test", permission: "permission-1",
                      requestJSON: #"{"toolCall":{"title":"Bash","rawInput":{"command":"printf approval-test"}},"options":[{"optionId":"yes","kind":"allow_once"},{"optionId":"no","kind":"reject_once"}]}"#),
                allow: true,
                through: { _ in
                    Issue.record("An unavailable daemon must not spend the native click")
                    return false
                }
            )
            #expect(result == .refused, "An unavailable daemon is retryable, not evidence that the request expired")
        }
    }
}
