import Foundation
import Testing
@testable import CmuxBrowser

@Suite
struct ReactGrabPastebackGateTests {
    @Test func armingMintsFreshTokensAndExposesTheRelaySyncToken() {
        var gate = ReactGrabPastebackGate()
        #expect(!gate.isArmed)
        #expect(gate.tokenForRelaySync == nil)

        let panelId = UUID()
        let firstToken = gate.arm(returnPanelId: panelId)
        #expect(gate.isArmed)
        #expect(gate.armedReturnPanelId == panelId)
        #expect(gate.tokenForRelaySync == firstToken)
        #expect(!firstToken.isEmpty)

        let secondToken = gate.arm(returnPanelId: panelId)
        #expect(firstToken != secondToken, "re-arming must mint a fresh token")
        #expect(gate.tokenForRelaySync == secondToken)
    }

    @Test func unarmedDeliveryIsRejectedWithoutStateChange() {
        var gate = ReactGrabPastebackGate()
        let verdict = gate.acceptDelivery(
            token: "anything",
            contentUTF8Count: 10,
            isMainFrame: true
        )
        #expect(verdict == .rejectedUnarmed)
        #expect(!gate.isArmed)
    }

    @Test func subframeDeliveryIsRejectedAndCannotBurnTheArm() {
        var gate = ReactGrabPastebackGate()
        let panelId = UUID()
        let token = gate.arm(returnPanelId: panelId)

        let subframeVerdict = gate.acceptDelivery(
            token: token,
            contentUTF8Count: 10,
            isMainFrame: false
        )
        #expect(subframeVerdict == .rejectedSubframe)
        #expect(gate.isArmed, "a subframe must not consume the user's arm")

        let mainFrameVerdict = gate.acceptDelivery(
            token: token,
            contentUTF8Count: 10,
            isMainFrame: true
        )
        #expect(mainFrameVerdict == .accepted(returnPanelId: panelId))
    }

    @Test func tokenMismatchRejectsAndDisarms() {
        var gate = ReactGrabPastebackGate()
        _ = gate.arm(returnPanelId: UUID())
        let verdict = gate.acceptDelivery(
            token: "forged-token",
            contentUTF8Count: 10,
            isMainFrame: true
        )
        #expect(verdict == .rejectedTokenMismatch)
        #expect(!gate.isArmed)
    }

    @Test func missingTokenRejectsAndDisarms() {
        var gate = ReactGrabPastebackGate()
        _ = gate.arm(returnPanelId: UUID())
        let verdict = gate.acceptDelivery(
            token: nil,
            contentUTF8Count: 10,
            isMainFrame: true
        )
        #expect(verdict == .rejectedTokenMismatch)
        #expect(!gate.isArmed)
    }

    @Test func validDeliveryAcceptsExactlyOnce() {
        var gate = ReactGrabPastebackGate()
        let panelId = UUID()
        let token = gate.arm(returnPanelId: panelId)

        let first = gate.acceptDelivery(
            token: token,
            contentUTF8Count: 128,
            isMainFrame: true
        )
        #expect(first == .accepted(returnPanelId: panelId))
        #expect(!gate.isArmed, "a successful delivery must disarm the gate")

        let second = gate.acceptDelivery(
            token: token,
            contentUTF8Count: 128,
            isMainFrame: true
        )
        #expect(second == .rejectedUnarmed)
    }

    @Test func oversizeContentIsRejectedAndConsumesTheArm() {
        var gate = ReactGrabPastebackGate()
        let token = gate.arm(returnPanelId: UUID())
        let verdict = gate.acceptDelivery(
            token: token,
            contentUTF8Count: ReactGrabPastebackGate.maxContentUTF8Bytes + 1,
            isMainFrame: true
        )
        #expect(verdict == .rejectedOversizeContent)
        #expect(!gate.isArmed)
    }

    @Test func contentAtTheBoundIsAccepted() {
        var gate = ReactGrabPastebackGate()
        let panelId = UUID()
        let token = gate.arm(returnPanelId: panelId)
        let verdict = gate.acceptDelivery(
            token: token,
            contentUTF8Count: ReactGrabPastebackGate.maxContentUTF8Bytes,
            isMainFrame: true
        )
        #expect(verdict == .accepted(returnPanelId: panelId))
    }

    @Test func rearmingInvalidatesThePreviousToken() {
        var gate = ReactGrabPastebackGate()
        let panelId = UUID()
        let oldToken = gate.arm(returnPanelId: panelId)
        let newToken = gate.arm(returnPanelId: panelId)

        let staleVerdict = gate.acceptDelivery(
            token: oldToken,
            contentUTF8Count: 10,
            isMainFrame: true
        )
        #expect(staleVerdict == .rejectedTokenMismatch)
        #expect(!gate.isArmed)

        _ = gate.arm(returnPanelId: panelId, token: newToken)
        let freshVerdict = gate.acceptDelivery(
            token: newToken,
            contentUTF8Count: 10,
            isMainFrame: true
        )
        #expect(freshVerdict == .accepted(returnPanelId: panelId))
    }

    @Test func disarmClearsAllState() {
        var gate = ReactGrabPastebackGate()
        let token = gate.arm(returnPanelId: UUID())
        gate.disarm()
        #expect(!gate.isArmed)
        #expect(gate.armedReturnPanelId == nil)
        #expect(gate.tokenForRelaySync == nil)
        let verdict = gate.acceptDelivery(
            token: token,
            contentUTF8Count: 10,
            isMainFrame: true
        )
        #expect(verdict == .rejectedUnarmed)
    }

    @Test func constantTimeEqualsMatchesStringEquality() {
        #expect(ReactGrabPastebackGate.constantTimeEquals("", ""))
        #expect(ReactGrabPastebackGate.constantTimeEquals("abc-123", "abc-123"))
        #expect(!ReactGrabPastebackGate.constantTimeEquals("abc-123", "abc-124"))
        #expect(!ReactGrabPastebackGate.constantTimeEquals("abc", "abcd"))
        #expect(!ReactGrabPastebackGate.constantTimeEquals("abcd", "abc"))
        #expect(!ReactGrabPastebackGate.constantTimeEquals("", "a"))
        #expect(ReactGrabPastebackGate.constantTimeEquals("ü🙂", "ü🙂"))
        #expect(!ReactGrabPastebackGate.constantTimeEquals("ü🙂", "ü🙃"))
    }
}
