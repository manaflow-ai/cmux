import CmuxTerminalCore
import Foundation
import Testing
@testable import CmuxAgentPromptCore

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
    @Test func inFlightQueueRetainsEachRequestTargetSurface() {
        let service = AgentPromptSubmissionService(maximumPendingRequests: 8)
        let workspaceID = UUID()
        let firstSurfaceID = UUID()
        let secondSurfaceID = UUID()
        var deliveryAttempts = 0
        let delivery: AgentPromptSubmissionService.Delivery = { _ in
            deliveryAttempts += 1
            return .submitted(
                workspaceID: workspaceID,
                surfaceID: deliveryAttempts == 1
                    ? firstSurfaceID
                    : secondSurfaceID,
                queued: false
            )
        }

        let first = service.submit(
            workspaceID: workspaceID,
            requestedSurfaceID: firstSurfaceID,
            text: "first",
            delivery: delivery
        )
        let second = service.submit(
            workspaceID: workspaceID,
            requestedSurfaceID: secondSurfaceID,
            text: "second",
            delivery: delivery
        )

        #expect(first.result == .submitted(
            workspaceID: workspaceID,
            surfaceID: firstSurfaceID,
            queued: false
        ))
        #expect(second.result == .queued(
            workspaceID: workspaceID,
            surfaceID: secondSurfaceID,
            reason: "prior_prompt_in_flight"
        ))

        let removed = service.remove(surfaceID: firstSurfaceID)
        #expect(removed.map(\.messageID) == [first.messageID])
        #expect(service.pendingCount == 1)
        #expect(service.drain(workspaceID: workspaceID).map(\.messageID) == [
            second.messageID,
        ])
    }

    @MainActor
    @Test func workspaceFIFOKeepsAutoResolveRequestsUnpinned() {
        let service = AgentPromptSubmissionService(maximumPendingRequests: 8)
        let workspaceID = UUID()
        let firstSurfaceID = UUID()
        let secondSurfaceID = UUID()
        var deliveryAttempts = 0
        let delivery: AgentPromptSubmissionService.Delivery = { _ in
            deliveryAttempts += 1
            if deliveryAttempts == 1 {
                return .rejectedComposerBusy(
                    workspaceID: workspaceID,
                    surfaceID: firstSurfaceID
                )
            }
            return .submitted(
                workspaceID: workspaceID,
                surfaceID: secondSurfaceID,
                queued: false
            )
        }

        let first = service.submit(
            workspaceID: workspaceID,
            requestedSurfaceID: firstSurfaceID,
            text: "first",
            delivery: delivery
        )
        let second = service.submit(
            workspaceID: workspaceID,
            requestedSurfaceID: nil,
            text: "auto-resolve",
            delivery: delivery
        )

        #expect(first.result == .queued(
            workspaceID: workspaceID,
            surfaceID: firstSurfaceID,
            reason: "human_composer_busy"
        ))
        #expect(second.result == .queued(
            workspaceID: workspaceID,
            surfaceID: nil,
            reason: "workspace_fifo"
        ))

        #expect(service.remove(surfaceID: firstSurfaceID).map(\.messageID) == [
            first.messageID,
        ])
        let drained = service.drain(workspaceID: workspaceID)
        #expect(drained.map(\.messageID) == [second.messageID])
        #expect(drained.first?.result == .submitted(
            workspaceID: workspaceID,
            surfaceID: secondSurfaceID,
            queued: false
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

    @MainActor
    @Test func directQueuedDeliveryRemainsTheFirstFIFORequest() {
        let service = AgentPromptSubmissionService(maximumPendingRequests: 8)
        let workspaceID = UUID()
        let surfaceID = UUID()
        let state = SubmissionTestState()

        let first = service.submit(
            workspaceID: workspaceID,
            requestedSurfaceID: surfaceID,
            text: "first",
            delivery: { _ in
                state.deliveryAttempts += 1
                return state.deliveryAttempts == 1
                    ? .queued(
                        workspaceID: workspaceID,
                        surfaceID: surfaceID,
                        reason: "runtime_starting"
                    )
                    : .submitted(
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

        #expect(first.result == .queued(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            reason: "runtime_starting"
        ))
        #expect(second.result == .queued(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            reason: "workspace_fifo"
        ))
        #expect(service.pendingCount == 2)

        let drained = service.drain(workspaceID: workspaceID)
        #expect(drained.map(\.messageID) == [first.messageID])
        #expect(service.confirm(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            messageID: first.messageID
        ))
        #expect(service.drain(workspaceID: workspaceID).map(\.messageID) == [
            second.messageID,
        ])
    }

    @MainActor
    @Test func terminalQueuedDeliveryIsNotRequeuedByTheService() {
        let workspaceID = UUID()
        let surfaceID = UUID()
        let service = AgentPromptSubmissionService(maximumPendingRequests: 8)
        let terminalQueued: AgentPromptSubmissionService.Delivery = { _ in
            .submitted(
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                queued: true
            )
        }

        let first = service.submit(
            workspaceID: workspaceID,
            requestedSurfaceID: surfaceID,
            text: "cold prompt",
            delivery: terminalQueued
        )

        #expect(first.result == .submitted(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            queued: true
        ))
        #expect(service.pendingCount == 0)
        #expect(service.drain(workspaceID: workspaceID).isEmpty)
    }

    @MainActor
    @Test func terminalQueuedDeliveryRemovesAnAlreadyRetainedRequest() {
        let workspaceID = UUID()
        let surfaceID = UUID()
        let service = AgentPromptSubmissionService(maximumPendingRequests: 8)
        var attempts = 0
        let delivery: AgentPromptSubmissionService.Delivery = { _ in
            attempts += 1
            if attempts == 1 {
                return .agentScopeUnavailable(
                    workspaceID: workspaceID,
                    surfaceID: surfaceID
                )
            }
            return .submitted(
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                queued: true
            )
        }

        let first = service.submit(
            workspaceID: workspaceID,
            requestedSurfaceID: surfaceID,
            text: "retained cold prompt",
            delivery: delivery
        )
        #expect(first.result == .queued(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            reason: "agent_not_ready"
        ))

        let drained = service.drain(workspaceID: workspaceID)
        #expect(drained.count == 1)
        #expect(drained.first?.result == .submitted(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            queued: true
        ))
        #expect(service.pendingCount == 0)
    }

    @MainActor
    @Test func drainDropsAgentNotFoundAndContinuesTheWorkspaceFIFO() {
        let workspaceID = UUID()
        let firstSurfaceID = UUID()
        let secondSurfaceID = UUID()
        let service = AgentPromptSubmissionService(maximumPendingRequests: 8)
        var deliveryAttempts = 0
        let delivery: AgentPromptSubmissionService.Delivery = { _ in
            deliveryAttempts += 1
            if deliveryAttempts == 1 {
                return .agentBusy(
                    workspaceID: workspaceID,
                    surfaceID: firstSurfaceID
                )
            }
            if deliveryAttempts == 2 {
                return .agentNotFound(
                    workspaceID: workspaceID,
                    requestedSurfaceID: firstSurfaceID
                )
            }
            return .submitted(
                workspaceID: workspaceID,
                surfaceID: secondSurfaceID,
                queued: false
            )
        }

        let first = service.submit(
            workspaceID: workspaceID,
            requestedSurfaceID: firstSurfaceID,
            text: "first",
            delivery: delivery
        )
        let second = service.submit(
            workspaceID: workspaceID,
            requestedSurfaceID: secondSurfaceID,
            text: "second",
            delivery: delivery
        )
        #expect(first.result == .queued(
            workspaceID: workspaceID,
            surfaceID: firstSurfaceID,
            reason: "agent_turn_active"
        ))
        #expect(second.result == .queued(
            workspaceID: workspaceID,
            surfaceID: secondSurfaceID,
            reason: "workspace_fifo"
        ))
        #expect(service.pendingByteCount == "first".utf8.count + "second".utf8.count)

        let drained = service.drain(workspaceID: workspaceID)
        #expect(drained.map(\.messageID) == [first.messageID, second.messageID])
        #expect(drained.first?.result == .agentNotFound(
            workspaceID: workspaceID,
            requestedSurfaceID: firstSurfaceID
        ))
        #expect(drained.last?.result == .submitted(
            workspaceID: workspaceID,
            surfaceID: secondSurfaceID,
            queued: false
        ))
        #expect(service.pendingCount == 0)
        #expect(service.pendingByteCount == 0)
    }

    @MainActor
    @Test func drainDropsAmbiguousAgentAndReleasesItsQueueEntry() {
        let workspaceID = UUID()
        let firstSurfaceID = UUID()
        let secondSurfaceID = UUID()
        let service = AgentPromptSubmissionService(maximumPendingRequests: 8)
        var deliveryAttempts = 0
        let delivery: AgentPromptSubmissionService.Delivery = { _ in
            deliveryAttempts += 1
            if deliveryAttempts == 1 {
                return .agentBusy(
                    workspaceID: workspaceID,
                    surfaceID: firstSurfaceID
                )
            }
            if deliveryAttempts == 2 {
                return .ambiguousAgent(
                    workspaceID: workspaceID,
                    surfaceIDs: [firstSurfaceID, secondSurfaceID]
                )
            }
            return .submitted(
                workspaceID: workspaceID,
                surfaceID: secondSurfaceID,
                queued: false
            )
        }

        let first = service.submit(
            workspaceID: workspaceID,
            requestedSurfaceID: nil,
            text: "first",
            delivery: delivery
        )
        let second = service.submit(
            workspaceID: workspaceID,
            requestedSurfaceID: secondSurfaceID,
            text: "second",
            delivery: delivery
        )
        #expect(first.result == .queued(
            workspaceID: workspaceID,
            surfaceID: firstSurfaceID,
            reason: "agent_turn_active"
        ))
        #expect(second.result == .queued(
            workspaceID: workspaceID,
            surfaceID: secondSurfaceID,
            reason: "workspace_fifo"
        ))
        #expect(service.pendingByteCount == "first".utf8.count + "second".utf8.count)

        let drained = service.drain(workspaceID: workspaceID)
        #expect(drained.map(\.messageID) == [first.messageID, second.messageID])
        #expect(drained.first?.result == .ambiguousAgent(
            workspaceID: workspaceID,
            surfaceIDs: [firstSurfaceID, secondSurfaceID]
        ))
        #expect(drained.last?.result == .submitted(
            workspaceID: workspaceID,
            surfaceID: secondSurfaceID,
            queued: false
        ))
        #expect(service.pendingCount == 0)
        #expect(service.pendingByteCount == 0)
    }

    @MainActor
    @Test func reentrantSubmissionCannotOvertakeTheActiveDelivery() {
        let service = AgentPromptSubmissionService(maximumPendingRequests: 8)
        let workspaceID = UUID()
        let surfaceID = UUID()
        let state = SubmissionTestState()

        let first = service.submit(
            workspaceID: workspaceID,
            requestedSurfaceID: surfaceID,
            text: "first",
            delivery: { _ in
                if !state.didReenter {
                    state.didReenter = true
                    state.nestedReceipt = service.submit(
                        workspaceID: workspaceID,
                        requestedSurfaceID: surfaceID,
                        text: "nested",
                        delivery: { _ in
                            .submitted(
                                workspaceID: workspaceID,
                                surfaceID: surfaceID,
                                queued: false
                            )
                        }
                    )
                }
                return .submitted(
                    workspaceID: workspaceID,
                    surfaceID: surfaceID,
                    queued: false
                )
            }
        )

        #expect(first.result == .submitted(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            queued: false
        ))
        #expect(state.nestedReceipt?.result == .queued(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            reason: "workspace_fifo"
        ))
        #expect(service.pendingCount == 1)
        #expect(service.confirm(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            messageID: first.messageID
        ))
        #expect(service.drain(workspaceID: workspaceID).count == 1)
    }

    @MainActor
    @Test func hookConfirmationDuringDeliveryReleasesBarrierWithoutStall() {
        let service = AgentPromptSubmissionService(maximumPendingRequests: 8)
        let workspaceID = UUID()
        let surfaceID = UUID()
        let state = SubmissionTestState()

        let first = service.submit(
            workspaceID: workspaceID,
            requestedSurfaceID: surfaceID,
            text: "first",
            delivery: { messageID in
                #expect(service.confirm(
                    workspaceID: workspaceID,
                    surfaceID: surfaceID,
                    messageID: messageID
                ))
                state.nestedReceipt = service.submit(
                    workspaceID: workspaceID,
                    requestedSurfaceID: surfaceID,
                    text: "nested",
                    delivery: { _ in
                        .submitted(
                            workspaceID: workspaceID,
                            surfaceID: surfaceID,
                            queued: false
                        )
                    }
                )
                return .submitted(
                    workspaceID: workspaceID,
                    surfaceID: surfaceID,
                    queued: false
                )
            }
        )

        #expect(first.result == .submitted(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            queued: false
        ))
        #expect(state.nestedReceipt?.result == .queued(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            reason: "workspace_fifo"
        ))
        #expect(!service.hasInFlight(workspaceID: workspaceID))
        #expect(service.drain(workspaceID: workspaceID).map(\.messageID) == [
            state.nestedReceipt?.messageID,
        ].compactMap { $0 })
    }

    @MainActor
    @Test func terminalDrainAndRemovalReconcilePendingByteBudget() {
        let workspaceID = UUID()
        let surfaceID = UUID()
        let gate = DeliveryGate()
        let service = AgentPromptSubmissionService(maximumPendingRequests: 8)
        let accepting: AgentPromptSubmissionService.Delivery = { _ in
            guard gate.isReady else {
                return .rejectedComposerBusy(
                    workspaceID: workspaceID,
                    surfaceID: surfaceID
                )
            }
            return .workspaceNotFound(workspaceID: workspaceID)
        }

        _ = service.submit(
            workspaceID: workspaceID,
            requestedSurfaceID: surfaceID,
            text: "terminal",
            delivery: accepting
        )
        #expect(service.pendingCount == 1)
        #expect(service.pendingByteCount == "terminal".utf8.count)

        gate.isReady = true
        let terminalReceipts = service.drain(workspaceID: workspaceID)
        #expect(terminalReceipts.count == 1)
        #expect(service.pendingCount == 0)
        #expect(service.pendingByteCount == 0)

        gate.isReady = false
        _ = service.submit(
            workspaceID: workspaceID,
            requestedSurfaceID: surfaceID,
            text: "remove-me",
            delivery: accepting
        )
        #expect(service.pendingByteCount == "remove-me".utf8.count)
        #expect(service.remove(surfaceID: surfaceID).count == 1)
        #expect(service.pendingCount == 0)
        #expect(service.pendingByteCount == 0)
    }

    @MainActor
    @Test func admissionBoundsRejectOversizeAndRequestBudgetThenRecover() {
        let workspaceID = UUID()
        let surfaceID = UUID()
        let service = AgentPromptSubmissionService(maximumPendingRequests: 1)
        let busy: AgentPromptSubmissionService.Delivery = { _ in
            .rejectedComposerBusy(
                workspaceID: workspaceID,
                surfaceID: surfaceID
            )
        }

        let oversized = service.submit(
            workspaceID: workspaceID,
            requestedSurfaceID: surfaceID,
            text: String(
                repeating: "x",
                count: AgentPromptSubmissionService.maximumPromptBytes + 1
            ),
            delivery: busy
        )
        guard case .promptTooLarge = oversized.result else {
            Issue.record("Expected the maximum prompt bound to reject the request")
            return
        }

        let first = service.submit(
            workspaceID: workspaceID,
            requestedSurfaceID: surfaceID,
            text: "first",
            delivery: busy
        )
        let full = service.submit(
            workspaceID: workspaceID,
            requestedSurfaceID: surfaceID,
            text: "second",
            delivery: busy
        )
        guard case .queued = first.result else {
            Issue.record("Expected the first request to occupy the bounded queue")
            return
        }
        guard case .submissionQueueFull = full.result else {
            Issue.record("Expected the second request to hit the request bound")
            return
        }
        #expect(service.remove(workspaceID: workspaceID).count == 1)
        #expect(service.pendingCount == 0)
        #expect(service.pendingByteCount == 0)
    }

    @MainActor
    @Test func idleWorkspaceBypassesGlobalPendingQueueBound() {
        let queuedWorkspaceID = UUID()
        let readyWorkspaceID = UUID()
        let queuedSurfaceID = UUID()
        let readySurfaceID = UUID()
        let service = AgentPromptSubmissionService(maximumPendingRequests: 1)
        let busy: AgentPromptSubmissionService.Delivery = { _ in
            .rejectedComposerBusy(
                workspaceID: queuedWorkspaceID,
                surfaceID: queuedSurfaceID
            )
        }

        let queued = service.submit(
            workspaceID: queuedWorkspaceID,
            requestedSurfaceID: queuedSurfaceID,
            text: "held",
            delivery: busy
        )
        #expect(queued.result == .queued(
            workspaceID: queuedWorkspaceID,
            surfaceID: queuedSurfaceID,
            reason: "human_composer_busy"
        ))

        let submitted = service.submit(
            workspaceID: readyWorkspaceID,
            requestedSurfaceID: readySurfaceID,
            text: "ready",
            delivery: { _ in
                .submitted(
                    workspaceID: readyWorkspaceID,
                    surfaceID: readySurfaceID,
                    queued: false
                )
            }
        )
        #expect(submitted.result == .submitted(
            workspaceID: readyWorkspaceID,
            surfaceID: readySurfaceID,
            queued: false
        ))
        #expect(service.pendingCount == 1)
        #expect(service.pendingByteCount == "held".utf8.count)
    }

    @MainActor
    @Test func byteBudgetRejectsTheNinthMaximumSizedPendingPrompt() {
        let workspaceID = UUID()
        let surfaceID = UUID()
        let service = AgentPromptSubmissionService(maximumPendingRequests: 32)
        let busy: AgentPromptSubmissionService.Delivery = { _ in
            .rejectedComposerBusy(
                workspaceID: workspaceID,
                surfaceID: surfaceID
            )
        }
        let prompt = String(
            repeating: "x",
            count: AgentPromptSubmissionService.maximumPromptBytes
        )

        for _ in 0..<8 {
            let receipt = service.submit(
                workspaceID: workspaceID,
                requestedSurfaceID: surfaceID,
                text: prompt,
                delivery: busy
            )
            guard case .queued = receipt.result else {
                Issue.record("Expected each of the first eight prompts to queue")
                return
            }
        }
        #expect(
            service.pendingByteCount
                == 8 * AgentPromptSubmissionService.maximumPromptBytes
        )
        let ninth = service.submit(
            workspaceID: workspaceID,
            requestedSurfaceID: surfaceID,
            text: prompt,
            delivery: busy
        )
        guard case .submissionQueueFull = ninth.result else {
            Issue.record("Expected the ninth maximum-sized prompt to hit the byte budget")
            return
        }
        #expect(service.remove(workspaceID: workspaceID).count == 8)
        #expect(service.pendingCount == 0)
        #expect(service.pendingByteCount == 0)
    }
}
