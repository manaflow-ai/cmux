import CmuxTerminalDomain
import Foundation
import Testing

@Suite struct TerminalDomainValueTests {
    @Test func deliveryResultsDistinguishAcceptedInput() {
        #expect(InputSendResult.sent.accepted)
        #expect(InputSendResult.queued.accepted)
        #expect(!InputSendResult.inputQueueFull.accepted)
        #expect(!InputSendResult.surfaceUnavailable.accepted)
        #expect(!InputSendResult.processExited.accepted)
        #expect(NamedKeySendResult.sent.accepted)
        #expect(!NamedKeySendResult.unknownKey.accepted)
    }

    @Test func portalPolicyRejectsDetachedReplacement() {
        let policy = PortalHostLeasePolicy()
        let currentOwner = NSObject()
        let detachedCandidate = NSObject()
        let paneID = UUID()
        let current = PortalHostLease(
            hostId: ObjectIdentifier(currentOwner),
            paneId: paneID,
            instanceSerial: 1,
            inWindow: true,
            area: 100
        )
        let candidate = PortalHostLease(
            hostId: ObjectIdentifier(detachedCandidate),
            paneId: paneID,
            instanceSerial: 2,
            inWindow: false,
            area: 100
        )

        #expect(!policy.shouldReplace(
            current: current,
            with: candidate,
            allowsSamePaneReplacement: true
        ))
    }
}
