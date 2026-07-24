import Foundation

// Wire types for the multiplayer workspace share protocol
// (plans/feat-multiplayer-share/DESIGN.md). One JSON object per WebSocket
// frame; key names match the design doc exactly (mixed camelCase and
// snake_case like `data_b64` are intentional).

// MARK: - Workspace shape

struct ShareWorkspaceSize: Codable, Equatable, Sendable {
    let width: Double
    let height: Double
}

/// Normalized [0,1] rectangle within the shared workspace container.
struct ShareRect: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
    let w: Double
    let h: Double
}

struct ShareWorkspacePane: Codable, Equatable, Sendable {
    let id: String
    let kind: String
    let title: String
    let rect: ShareRect
    var surfaceId: String?
    var cols: Int?
    var rows: Int?
    /// Byte-stream sequence of the first byte in `replay_b64` (snapshot only).
    var replaySeq: UInt64?
    var replay_b64: String?
}

struct ShareWorkspace: Codable, Equatable, Sendable {
    let title: String
    let size: ShareWorkspaceSize
    var panes: [ShareWorkspacePane]
}

// MARK: - Participants

struct ShareParticipant: Codable, Equatable, Sendable {
    let id: String
    let email: String
    let name: String
    let color: Int
    let role: String

    var isHost: Bool { role == "host" }
}

// MARK: - Host -> DO frames

enum ShareOutboundFrame: Equatable, Sendable {
    case joinResponse(requestId: String, allow: Bool)
    case snapshot(to: String, workspace: ShareWorkspace)
    case layout(workspace: ShareWorkspace)
    case term(surfaceId: String, seq: UInt64, dataB64: String)
    case termResize(surfaceId: String, cols: Int, rows: Int)
    case textbox(paneId: String, text: String, selStart: Int, selEnd: Int, active: Bool)
    case cursor(x: Double, y: Double)
    case chat(text: String, x: Double, y: Double)
    case end
}

extension ShareOutboundFrame: Encodable {
    private enum CodingKeys: String, CodingKey {
        case type, requestId, allow, to, workspace, surfaceId, seq
        case dataB64 = "data_b64"
        case cols, rows, paneId, text, selStart, selEnd, active, x, y
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .joinResponse(let requestId, let allow):
            try container.encode("join_response", forKey: .type)
            try container.encode(requestId, forKey: .requestId)
            try container.encode(allow, forKey: .allow)
        case .snapshot(let to, let workspace):
            try container.encode("snapshot", forKey: .type)
            try container.encode(to, forKey: .to)
            try container.encode(workspace, forKey: .workspace)
        case .layout(let workspace):
            try container.encode("layout", forKey: .type)
            try container.encode(workspace, forKey: .workspace)
        case .term(let surfaceId, let seq, let dataB64):
            try container.encode("term", forKey: .type)
            try container.encode(surfaceId, forKey: .surfaceId)
            try container.encode(seq, forKey: .seq)
            try container.encode(dataB64, forKey: .dataB64)
        case .termResize(let surfaceId, let cols, let rows):
            try container.encode("term_resize", forKey: .type)
            try container.encode(surfaceId, forKey: .surfaceId)
            try container.encode(cols, forKey: .cols)
            try container.encode(rows, forKey: .rows)
        case .textbox(let paneId, let text, let selStart, let selEnd, let active):
            try container.encode("textbox", forKey: .type)
            try container.encode(paneId, forKey: .paneId)
            try container.encode(text, forKey: .text)
            try container.encode(selStart, forKey: .selStart)
            try container.encode(selEnd, forKey: .selEnd)
            try container.encode(active, forKey: .active)
        case .cursor(let x, let y):
            try container.encode("cursor", forKey: .type)
            try container.encode(x, forKey: .x)
            try container.encode(y, forKey: .y)
        case .chat(let text, let x, let y):
            try container.encode("chat", forKey: .type)
            try container.encode(text, forKey: .text)
            try container.encode(x, forKey: .x)
            try container.encode(y, forKey: .y)
        case .end:
            try container.encode("end", forKey: .type)
        }
    }

    func encodedJSONData() throws -> Data {
        try JSONEncoder().encode(self)
    }
}

// MARK: - DO -> host frames

enum ShareInboundFrame: Equatable, Sendable {
    case joinRequest(requestId: String, email: String, name: String)
    case syncRequest(participantId: String)
    case cursor(participantId: String, x: Double, y: Double)
    case chat(participantId: String, ts: Double, text: String, x: Double, y: Double)
    case presence(participants: [ShareParticipant])
    case ended
    /// Forward-compatibility: unrecognized frame types are surfaced (and
    /// ignored by the service) instead of failing the decode loop.
    case unknown(type: String)
}

extension ShareInboundFrame: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type, requestId, email, name, participantId, x, y, ts, text, participants
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "join_request":
            self = .joinRequest(
                requestId: try container.decode(String.self, forKey: .requestId),
                email: try container.decodeIfPresent(String.self, forKey: .email) ?? "",
                name: try container.decodeIfPresent(String.self, forKey: .name) ?? ""
            )
        case "sync_request":
            self = .syncRequest(participantId: try container.decode(String.self, forKey: .participantId))
        case "cursor":
            self = .cursor(
                participantId: try container.decodeIfPresent(String.self, forKey: .participantId) ?? "",
                x: try container.decode(Double.self, forKey: .x),
                y: try container.decode(Double.self, forKey: .y)
            )
        case "chat":
            self = .chat(
                participantId: try container.decodeIfPresent(String.self, forKey: .participantId) ?? "",
                ts: try container.decodeIfPresent(Double.self, forKey: .ts) ?? 0,
                text: try container.decode(String.self, forKey: .text),
                x: try container.decodeIfPresent(Double.self, forKey: .x) ?? 0.5,
                y: try container.decodeIfPresent(Double.self, forKey: .y) ?? 0.5
            )
        case "presence":
            self = .presence(participants: try container.decode([ShareParticipant].self, forKey: .participants))
        case "ended":
            self = .ended
        default:
            self = .unknown(type: type)
        }
    }

    static func decode(fromJSONData data: Data) throws -> ShareInboundFrame {
        try JSONDecoder().decode(ShareInboundFrame.self, from: data)
    }
}

// MARK: - Create-session HTTP response

struct ShareCreateResponse: Decodable, Sendable {
    let shareId: String
    let hostToken: String
    let url: String?
}

// MARK: - Replay capping

enum WorkspaceShareReplayCap {
    /// DESIGN.md caps `replay_b64` at 256 KB per pane. Base64 expands raw
    /// bytes 4/3, so cap the raw tail at 3/4 of the budget and keep the most
    /// recent bytes (the tail is what reconstructs the current screen).
    static let maximumBase64ByteCount = 256 * 1024

    static func cappedReplayTail(
        _ data: Data,
        maximumBase64ByteCount: Int = WorkspaceShareReplayCap.maximumBase64ByteCount
    ) -> Data {
        let maximumRawByteCount = (maximumBase64ByteCount / 4) * 3
        guard data.count > maximumRawByteCount else { return data }
        return Data(data.suffix(maximumRawByteCount))
    }
}
