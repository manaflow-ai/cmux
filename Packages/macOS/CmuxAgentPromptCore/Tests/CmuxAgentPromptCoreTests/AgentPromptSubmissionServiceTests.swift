import CmuxTerminalCore
import Foundation
import Testing
@testable import CmuxAgentPromptCore

@MainActor
private final class DeliveryGate {
    var isReady = false
}

@Suite("Agent prompt submission service")
struct AgentPromptSubmissionServiceTests {
    @MainActor
    @Test func addressedAdmissionReturnsMessageIDsAndDrainsFIFO() {
        let service = AgentPromptSubmissionService(maximumPendingRequests: 8)
        let workspaceID = UUID()
        let surfaceID = UUID()
        let gate = DeliveryGate()

        let first = service.submit(
            workspaceID: workspaceID,
            requestedSurfaceID: surfaceID,
            text: "first",
            delivery: { _ in
                guard gate.isReady else {
                    return .rejectedComposerBusy(
                        workspaceID: workspaceID,
                        surfaceID: surfaceID
                    )
                }
                return .submitted(
                    workspaceID: workspaceID,
                    surfaceID: surfaceID,
                    queued: false
                )
            }
        )
        let second = service.submit(
            workspaceID: workspaceID,
            requestedSurfaceID: surfaceID,
            text: "second",
            delivery: { _ in
                .submitted(
                    workspaceID: workspaceID,
                    surfaceID: surfaceID,
                    queued: false
                )
            }
        )

        #expect(first.messageID != second.messageID)
        #expect(first.result == .queued(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            reason: "human_composer_busy"
        ))
        #expect(second.result == .queued(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            reason: "workspace_fifo"
        ))

        gate.isReady = true
        let firstDrain = service.drain(workspaceID: workspaceID)
        #expect(firstDrain.map(\.messageID) == [first.messageID])
        #expect(service.confirm(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            messageID: first.messageID
        ))
        let secondDrain = service.drain(workspaceID: workspaceID)
        #expect((firstDrain + secondDrain).map(\.messageID) == [
            first.messageID,
            second.messageID,
        ])
    }

    @MainActor
    @Test func expiredBarrierAdvancesFIFOWithoutDuplicatingPromptState() {
        let acceptedAt = Date(timeIntervalSince1970: 10_000)
        let service = AgentPromptSubmissionService(
            maximumPendingRequests: 8,
            confirmationTimeout: 30,
            now: { acceptedAt }
        )
        let workspaceID = UUID()
        let surfaceID = UUID()
        let accepting: AgentPromptSubmissionService.Delivery = { _ in
            .submitted(
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                queued: false
            )
        }

        let first = service.submit(
            workspaceID: workspaceID,
            requestedSurfaceID: surfaceID,
            text: "first",
            delivery: accepting
        )
        let second = service.submit(
            workspaceID: workspaceID,
            requestedSurfaceID: surfaceID,
            text: "second",
            delivery: accepting
        )
        #expect(second.result == .queued(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            reason: "prior_prompt_in_flight"
        ))
        #expect(service.drain(workspaceID: workspaceID).isEmpty)

        #expect(service.expireStaleInFlight(
            workspaceID: workspaceID,
            now: acceptedAt.addingTimeInterval(31)
        ) == first.messageID)
        #expect(service.drain(workspaceID: workspaceID).map(\.messageID) == [
            second.messageID,
        ])
        #expect(!service.confirm(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            messageID: first.messageID
        ))
    }

    @MainActor
    @Test func zeroConfirmationWindowNeverWedgesLaterSubmissions() {
        let service = AgentPromptSubmissionService(
            maximumPendingRequests: 8,
            confirmationTimeout: 0,
            now: { Date(timeIntervalSince1970: 10_000) }
        )
        let workspaceID = UUID()
        let surfaceID = UUID()
        let accepting: AgentPromptSubmissionService.Delivery = { _ in
            .submitted(
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                queued: false
            )
        }

        let first = service.submit(
            workspaceID: workspaceID,
            requestedSurfaceID: surfaceID,
            text: "first",
            delivery: accepting
        )
        let second = service.submit(
            workspaceID: workspaceID,
            requestedSurfaceID: surfaceID,
            text: "second",
            delivery: accepting
        )

        guard case .submitted = first.result,
              case .submitted = second.result else {
            Issue.record("Expected both prompts to be admitted")
            return
        }
        #expect(first.messageID != second.messageID)
    }
}
