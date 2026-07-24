import Foundation

/// Validates decoded relay payloads before the host retains or applies them.
///
/// The 1 MiB frame ceiling bounds decoding allocation. These semantic limits
/// then bound retained collections and reject malformed protocol state before
/// it earns flow-control credit.
public struct WorkspaceShareInboundMessageValidator: Sendable {
    /// Creates a stateless validator.
    public init() {}

    /// Returns whether `message` is a valid, bounded logical server payload.
    ///
    /// `ack-request` is a flow-control marker rather than a logical payload and
    /// is intentionally rejected here. It is handled by the acknowledgement gate.
    public func acceptsPayload(_ message: ShareServerMessage) -> Bool {
        switch message {
        case .sessionState(let snapshot):
            return accepts(snapshot)
        case .accessRequest(let user, let email):
            return isID(user) && isEmail(email)
        case .presence(let participants):
            return accepts(participants)
        case .cursor(let user, let pos):
            return isID(user) && (pos.map(accepts) ?? true)
        case .chat(let message):
            return accepts(message)
        case .guestInput(let user, let ws, let pane, let data):
            return isID(user)
                && isID(ws)
                && isID(pane)
                && isBounded(
                    data,
                    maximumUTF8Bytes: ShareProtocolConstants.maximumTerminalInputBytes,
                    allowEmpty: false
                )
        case .guestSub(let ws, let pane, let count):
            return isID(ws)
                && isID(pane)
                && (0...ShareProtocolConstants.maximumConnections).contains(count)
        case .resync:
            return true
        case .sessionEnded(let reason):
            return reason == "host-stopped"
                || reason == "host-gone"
                || reason == "expired"
        case .error(let code, let message):
            return isBounded(
                code,
                maximumUTF8Bytes: ShareProtocolConstants.maximumIDBytes,
                allowEmpty: true
            ) && isBounded(
                message,
                maximumUTF8Bytes: ShareProtocolConstants.maximumChatTextBytes,
                allowEmpty: true
            )
        case .ackRequest, .unknown:
            return false
        }
    }

    private func accepts(_ snapshot: ShareSessionSnapshot) -> Bool {
        guard snapshot.proto == ShareProtocolConstants.version,
              snapshot.shared.count <= ShareProtocolConstants.maximumSharedWorkspaces,
              snapshot.layouts.count <= ShareProtocolConstants.maximumSharedWorkspaces,
              accepts(snapshot.participants),
              snapshot.chat.count <= ShareProtocolConstants.maximumChatMessages,
              snapshot.chat.allSatisfy(accepts),
              Set(snapshot.chat.map(\.id)).count == snapshot.chat.count,
              isID(snapshot.you.user),
              (0...1_000_000).contains(snapshot.you.color),
              snapshot.you.isHost else {
            return false
        }

        let sharedIDs = Set(snapshot.shared.map(\.id))
        guard sharedIDs.count == snapshot.shared.count,
              snapshot.shared.allSatisfy({
                  isID($0.id)
                      && isBounded(
                          $0.title,
                          maximumUTF8Bytes: ShareProtocolConstants.maximumTitleBytes,
                          allowEmpty: true
                      )
              }),
              Set(snapshot.layouts.map(\.ws)).count == snapshot.layouts.count,
              snapshot.layouts.allSatisfy({
                  sharedIDs.contains($0.ws) && accepts($0)
              }) else {
            return false
        }
        return true
    }

    private func accepts(_ participants: [ShareParticipant]) -> Bool {
        guard participants.count <= ShareProtocolConstants.maximumParticipants,
              Set(participants.map(\.user)).count == participants.count else {
            return false
        }
        return participants.allSatisfy { participant in
            isID(participant.user)
                && isEmail(participant.email)
                && (0...1_000_000).contains(participant.color)
                && (participant.focusWs.map(isID) ?? true)
        }
    }

    private func accepts(_ message: ShareChatMessage) -> Bool {
        isID(message.id)
            && isID(message.user)
            && isBounded(
                message.text,
                maximumUTF8Bytes: ShareProtocolConstants.maximumChatTextBytes,
                allowEmpty: true
            )
            && message.ts.isFinite
            && (message.bubble.map(accepts) ?? true)
    }

    private func accepts(_ cursor: ShareCursorPos) -> Bool {
        isID(cursor.ws)
            && isID(cursor.pane)
            && cursor.x.isFinite
            && cursor.y.isFinite
            && (0...1).contains(cursor.x)
            && (0...1).contains(cursor.y)
    }

    private func accepts(_ layout: ShareWorkspaceLayout) -> Bool {
        guard isID(layout.ws), let root = layout.tree else {
            return isID(layout.ws)
        }

        var stack: [(node: ShareLayoutNode, depth: Int)] = [(root, 1)]
        var nodeCount = 0
        var paneCount = 0
        var paneIDs = Set<String>()
        let maximumNodes = ShareProtocolConstants.maximumLayoutPanes * 2 - 1

        while let item = stack.popLast() {
            guard item.depth <= ShareProtocolConstants.maximumLayoutDepth,
                  nodeCount < maximumNodes else {
                return false
            }
            nodeCount += 1
            switch item.node {
            case .split(let axis, let ratio, let a, let b):
                guard (axis == "h" || axis == "v"),
                      ratio.isFinite,
                      ratio > 0,
                      ratio < 1 else {
                    return false
                }
                stack.append((b, item.depth + 1))
                stack.append((a, item.depth + 1))
            case .pane(let pane, let content, let cols, let rows, let title):
                guard paneCount < ShareProtocolConstants.maximumLayoutPanes,
                      isID(pane),
                      paneIDs.insert(pane).inserted,
                      content == "terminal"
                          || content == "browser"
                          || content == "agent"
                          || content == "other",
                      cols.map({ (1...10_000).contains($0) }) ?? true,
                      rows.map({ (1...10_000).contains($0) }) ?? true,
                      title.map({
                          isBounded(
                              $0,
                              maximumUTF8Bytes: ShareProtocolConstants.maximumTitleBytes,
                              allowEmpty: true
                          )
                      }) ?? true else {
                    return false
                }
                paneCount += 1
            }
        }
        return true
    }

    private func isID(_ value: String) -> Bool {
        isBounded(
            value,
            maximumUTF8Bytes: ShareProtocolConstants.maximumIDBytes,
            allowEmpty: false
        ) && value.unicodeScalars.allSatisfy({
            !CharacterSet.controlCharacters.contains($0)
        })
    }

    private func isEmail(_ value: String) -> Bool {
        isBounded(
            value,
            maximumUTF8Bytes: ShareProtocolConstants.maximumEmailBytes,
            allowEmpty: true
        ) && value.unicodeScalars.allSatisfy({
            !CharacterSet.controlCharacters.contains($0)
        })
    }

    private func isBounded(
        _ value: String,
        maximumUTF8Bytes: Int,
        allowEmpty: Bool
    ) -> Bool {
        let count = value.utf8.count
        return (allowEmpty || count > 0) && count <= maximumUTF8Bytes
    }
}
