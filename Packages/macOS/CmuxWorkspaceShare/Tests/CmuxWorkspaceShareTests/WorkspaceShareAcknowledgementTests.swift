import CmuxWorkspaceShare
import Foundation
import Testing

@Suite
struct WorkspaceShareAcknowledgementTests {
    private let nonce = ShareAckNonce(rawValue: "nonce-1")!

    @Test
    func `Only an adjacent accepted payload earns one acknowledgement`() {
        var gate = WorkspaceShareAcknowledgementGate()
        gate.connectionOpened()

        #expect(gate.acknowledgement(for: nonce, sequence: 0) == nil)

        gate.recordPayload(accepted: true, sequence: 1)
        #expect(gate.acknowledgement(for: nonce, sequence: 2) == nonce)
        #expect(gate.acknowledgement(for: nonce, sequence: 3) == nil)

        gate.recordPayload(accepted: false, sequence: 4)
        #expect(gate.acknowledgement(for: nonce, sequence: 5) == nil)

        gate.recordPayload(accepted: true, sequence: 6)
        #expect(gate.acknowledgement(for: nonce, sequence: 8) == nil)
    }

    @Test
    func `Reconnect clears credit and resync earns fresh adjacent credit`() {
        var gate = WorkspaceShareAcknowledgementGate()
        gate.connectionOpened()
        gate.recordPayload(accepted: true, sequence: 0)

        gate.connectionOpened()
        #expect(gate.acknowledgement(for: nonce, sequence: 1) == nil)

        // A newly decoded and accepted `resync` is a logical payload on the
        // new connection and earns only its following marker.
        gate.recordPayload(accepted: true, sequence: 0)
        #expect(gate.acknowledgement(for: nonce, sequence: 1) == nonce)
    }

    @Test
    func `Server and host text limits are exact`() {
        #expect(
            WorkspaceShareTextFramePolicy.acceptsServerFrame(
                byteCount: ShareProtocolConstants.serverJSONFrameByteLimit - 1
            )
        )
        #expect(
            !WorkspaceShareTextFramePolicy.acceptsServerFrame(
                byteCount: ShareProtocolConstants.serverJSONFrameByteLimit
            )
        )
        #expect(
            !WorkspaceShareTextFramePolicy.acceptsServerFrame(
                byteCount: ShareProtocolConstants.serverJSONFrameByteLimit + 1
            )
        )
        #expect(ShareProtocolConstants.messageTooBigCloseCode == 1_009)

        #expect(
            WorkspaceShareTextFramePolicy.acceptsHostFrame(
                byteCount: ShareProtocolConstants.maximumHostJSONFrameBytes - 1
            )
        )
        #expect(
            !WorkspaceShareTextFramePolicy.acceptsHostFrame(
                byteCount: ShareProtocolConstants.maximumHostJSONFrameBytes
            )
        )
    }

    @Test
    func `Near-max snapshot decodes into bounded state before ACK`() throws {
        let data = try nearMaximumSnapshotData()
        #expect(data.count < ShareProtocolConstants.serverJSONFrameByteLimit)
        #expect(
            data.count
                >= ShareProtocolConstants.serverJSONFrameByteLimit - 2_048
        )
        #expect(
            WorkspaceShareTextFramePolicy.acceptsServerFrame(byteCount: data.count)
        )

        let message = try JSONDecoder().decode(
            ShareServerMessage.self,
            from: data
        )
        let validator = WorkspaceShareInboundMessageValidator()
        #expect(validator.acceptsPayload(message))
        guard case .sessionState(let snapshot) = message else {
            Issue.record("Expected a session-state payload")
            return
        }
        #expect(
            snapshot.participants.count
                == ShareProtocolConstants.maximumParticipants
        )
        #expect(snapshot.participants.last?.user == "user-256")
        #expect(snapshot.chat.count == ShareProtocolConstants.maximumChatMessages)

        var gate = WorkspaceShareAcknowledgementGate()
        gate.connectionOpened()
        gate.recordPayload(accepted: true, sequence: 0)

        let markerData = Data(#"{"t":"ack-request","nonce":"snapshot-credit"}"#.utf8)
        let marker = try JSONDecoder().decode(
            ShareServerMessage.self,
            from: markerData
        )
        let markerNonce: ShareAckNonce
        if case .ackRequest(let decodedNonce) = marker {
            markerNonce = decodedNonce
        } else {
            Issue.record("Expected an acknowledgement marker")
            return
        }
        #expect(
            gate.acknowledgement(for: markerNonce, sequence: 1)
                == markerNonce
        )
    }

    @Test
    func `Near-max snapshot ACK bypasses a near-limit outbound grid`() throws {
        let snapshotData = try nearMaximumSnapshotData()
        let snapshot = try JSONDecoder().decode(
            ShareServerMessage.self,
            from: snapshotData
        )
        #expect(
            WorkspaceShareInboundMessageValidator().acceptsPayload(snapshot)
        )

        var gate = WorkspaceShareAcknowledgementGate()
        gate.connectionOpened()
        gate.recordPayload(accepted: true, sequence: 0)
        let acknowledged = gate.acknowledgement(
            for: ShareAckNonce(rawValue: "credit")!,
            sequence: 1
        )
        let credit = try #require(acknowledged)

        let headerBytes = 5
        let grid = try #require(
            ShareBinaryFrame.encode(
                kind: ShareProtocolConstants.binaryKindGrid,
                ws: "w",
                pane: "p",
                payload: Data(
                    repeating: 0x61,
                    count: ShareProtocolConstants.binaryFrameByteLimit
                        - headerBytes
                        - 1
                )
            )
        )
        let mailbox = WorkspaceShareOutboundMailbox<String>(
            maximumMessages: 256,
            maximumBytes: 4 * 1_024 * 1_024,
            reservedControlMessages: 16,
            reservedControlBytes: 64 * 1_024,
            reservedAcknowledgementMessages: 128,
            reservedAcknowledgementBytes: 64 * 1_024
        )
        #expect(mailbox.admit("grid", byteCount: grid.count, priority: .bulk))
        #expect(
            mailbox.admit(
                credit.rawValue,
                byteCount: credit.rawValue.utf8.count,
                priority: .acknowledgement
            )
        )

        let ackClaim = try #require(mailbox.claimNext())
        #expect(ackClaim.entry.payload == credit.rawValue)
        _ = try #require(mailbox.complete(ackClaim))
        #expect(mailbox.pendingBytes == grid.count)

        let gridClaim = try #require(mailbox.claimNext())
        #expect(gridClaim.entry.payload == "grid")
        _ = try #require(mailbox.complete(gridClaim))
        #expect(mailbox.pendingBytes == 0)
    }

    private func nearMaximumSnapshotData() throws -> Data {
        func encodedSnapshot(chatTextBytes: Int) throws -> Data {
            let shared = [
                ShareSharedWorkspace(id: "workspace-1", title: "Near maximum"),
            ]
            let layouts = [
                ShareWorkspaceLayout(
                    ws: "workspace-1",
                    tree: .pane(
                        pane: "pane-1",
                        content: "terminal",
                        cols: 120,
                        rows: 40,
                        title: "Terminal"
                    )
                ),
            ]
            let participants = (0..<ShareProtocolConstants.maximumParticipants)
                .map { index in
                    ShareParticipant(
                        user: "user-\(index)",
                        email: "user-\(index)@example.com",
                        role: index.isMultiple(of: 2) ? .editor : .viewer,
                        color: index,
                        focusWs: "workspace-1",
                        connected: true,
                        isHost: index == 0
                    )
                }
            let chat = (0..<ShareProtocolConstants.maximumChatMessages)
                .map { index in
                    ShareChatMessage(
                        id: "chat-\(index)",
                        user: "user-\(index % participants.count)",
                        text: String(repeating: "x", count: chatTextBytes),
                        bubble: nil,
                        ts: Double(index)
                    )
                }
            let snapshot = ShareSessionSnapshot(
                proto: ShareProtocolConstants.version,
                shared: shared,
                layouts: layouts,
                participants: participants,
                chat: chat,
                you: ShareSelfIdentity(
                    user: "user-0",
                    role: .editor,
                    color: 0,
                    isHost: true
                )
            )
            let snapshotData = try JSONEncoder().encode(snapshot)
            var object = try #require(
                JSONSerialization.jsonObject(with: snapshotData)
                    as? [String: Any]
            )
            object["t"] = "session-state"
            return try JSONSerialization.data(withJSONObject: object)
        }

        var low = 0
        var high = ShareProtocolConstants.maximumChatTextBytes
        var best = try encodedSnapshot(chatTextBytes: low)
        while low <= high {
            let candidateLength = low + (high - low) / 2
            let candidate = try encodedSnapshot(chatTextBytes: candidateLength)
            if candidate.count < ShareProtocolConstants.serverJSONFrameByteLimit {
                best = candidate
                low = candidateLength + 1
            } else {
                high = candidateLength - 1
            }
        }
        return best
    }
}
