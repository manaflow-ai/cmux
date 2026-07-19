import Foundation

// Swift mirror of `workers/share/src/protocol.ts` (cmux share protocol v1).
// Field names must stay byte-identical to the TypeScript definitions; the
// enum discriminator is the `t` field on every JSON envelope.

enum ShareProtocolConstants {
    static let version = 1
    static let binaryKindGrid: UInt8 = 0x01
    static let binaryKindPixel: UInt8 = 0x02
}

enum ShareRole: String, Codable, Sendable {
    case editor
    case viewer
}

struct ShareCursorPos: Codable, Equatable, Sendable {
    var ws: String
    var pane: String
    /// Normalized [0,1] within the pane.
    var x: Double
    var y: Double
}

struct ShareParticipant: Codable, Equatable, Sendable {
    var user: String
    var email: String
    var role: ShareRole
    /// Index into the shared color palette; host is always 0.
    var color: Int
    var focusWs: String?
    var connected: Bool
    var isHost: Bool
}

struct ShareChatMessage: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var user: String
    var text: String
    var bubble: ShareCursorPos?
    var ts: Double
}

struct ShareSharedWorkspace: Codable, Equatable, Sendable {
    var id: String
    var title: String
}

/// Pane-tree snapshot node mirroring the TS recursive `LayoutNode` union.
indirect enum ShareLayoutNode: Equatable, Sendable {
    case split(axis: String, ratio: Double, a: ShareLayoutNode, b: ShareLayoutNode)
    case pane(pane: String, content: String, cols: Int?, rows: Int?, title: String?)
}

extension ShareLayoutNode: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, axis, ratio, a, b, pane, content, cols, rows, title
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "split":
            self = .split(
                axis: try container.decode(String.self, forKey: .axis),
                ratio: try container.decode(Double.self, forKey: .ratio),
                a: try container.decode(ShareLayoutNode.self, forKey: .a),
                b: try container.decode(ShareLayoutNode.self, forKey: .b)
            )
        case "pane":
            self = .pane(
                pane: try container.decode(String.self, forKey: .pane),
                content: try container.decode(String.self, forKey: .content),
                cols: try container.decodeIfPresent(Int.self, forKey: .cols),
                rows: try container.decodeIfPresent(Int.self, forKey: .rows),
                title: try container.decodeIfPresent(String.self, forKey: .title)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container, debugDescription: "Unknown layout node kind: \(kind)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .split(let axis, let ratio, let a, let b):
            try container.encode("split", forKey: .kind)
            try container.encode(axis, forKey: .axis)
            try container.encode(ratio, forKey: .ratio)
            try container.encode(a, forKey: .a)
            try container.encode(b, forKey: .b)
        case .pane(let pane, let content, let cols, let rows, let title):
            try container.encode("pane", forKey: .kind)
            try container.encode(pane, forKey: .pane)
            try container.encode(content, forKey: .content)
            try container.encodeIfPresent(cols, forKey: .cols)
            try container.encodeIfPresent(rows, forKey: .rows)
            try container.encodeIfPresent(title, forKey: .title)
        }
    }
}

struct ShareWorkspaceLayout: Equatable, Sendable {
    var ws: String
    var tree: ShareLayoutNode?
}

extension ShareWorkspaceLayout: Codable {
    private enum CodingKeys: String, CodingKey { case ws, tree }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ws = try container.decode(String.self, forKey: .ws)
        tree = try container.decodeIfPresent(ShareLayoutNode.self, forKey: .tree)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ws, forKey: .ws)
        // The TS type is `LayoutNode | null`; emit an explicit null.
        if let tree {
            try container.encode(tree, forKey: .tree)
        } else {
            try container.encodeNil(forKey: .tree)
        }
    }
}

// MARK: - Composer co-editing (slice 2)

/// One text edit at codepoint position `p`: delete `d` codepoints, then
/// insert `i` (mirrors `ComposeOp` in protocol.ts; indices are codepoints,
/// i.e. unicode scalars, not UTF-16 units).
struct ShareComposeOp: Codable, Equatable, Sendable {
    var p: Int
    var d: Int?
    var i: String?
}

struct ShareCaretRange: Codable, Equatable, Sendable {
    var start: Int
    var end: Int
}

struct ShareComposeCaret: Codable, Equatable, Sendable {
    var user: String
    var start: Int
    var end: Int
}

/// Guest pointer event over a shared browser pane (normalized coords).
struct ShareGuestPointer: Codable, Equatable, Sendable {
    var user: String
    var ws: String
    var pane: String
    /// "move" | "down" | "up" | "wheel"
    var action: String
    var x: Double
    var y: Double
    var button: Int?
    var dx: Double?
    var dy: Double?
}

/// Guest keyboard event over a shared browser pane.
struct ShareGuestWebKey: Codable, Equatable, Sendable {
    var user: String
    var ws: String
    var pane: String
    var key: String
    var code: String
    var down: Bool
    var alt: Bool?
    var ctrl: Bool?
    var meta: Bool?
    var shift: Bool?
}

// MARK: - Host -> DO

enum ShareHostMessage {
    case hello(shared: [ShareSharedWorkspace], layouts: [ShareWorkspaceLayout])
    case layout(ShareWorkspaceLayout)
    case shared([ShareSharedWorkspace])
    case approve(user: String, role: ShareRole)
    case deny(user: String)
    case kick(user: String)
    case role(user: String, role: ShareRole)
    case cursor(ShareCursorPos?)
    case chat(text: String, bubble: ShareCursorPos?)
    /// Which workspace the host is currently viewing (drives follow-the-host).
    case focus(ws: String?)
    /// Authoritative composer state after applying (rebased) guest ops.
    case composeState(field: String, rev: Int, text: String, carets: [ShareComposeCaret])
    case end
}

extension ShareHostMessage: Encodable {
    private enum CodingKeys: String, CodingKey {
        case t, proto, shared, layouts, layout, user, role, pos, text, bubble, ws
        case field, rev, carets
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hello(let shared, let layouts):
            try container.encode("hello", forKey: .t)
            try container.encode(ShareProtocolConstants.version, forKey: .proto)
            try container.encode(shared, forKey: .shared)
            try container.encode(layouts, forKey: .layouts)
        case .layout(let layout):
            try container.encode("layout", forKey: .t)
            try container.encode(layout, forKey: .layout)
        case .shared(let shared):
            try container.encode("shared", forKey: .t)
            try container.encode(shared, forKey: .shared)
        case .approve(let user, let role):
            try container.encode("approve", forKey: .t)
            try container.encode(user, forKey: .user)
            try container.encode(role, forKey: .role)
        case .deny(let user):
            try container.encode("deny", forKey: .t)
            try container.encode(user, forKey: .user)
        case .kick(let user):
            try container.encode("kick", forKey: .t)
            try container.encode(user, forKey: .user)
        case .role(let user, let role):
            try container.encode("role", forKey: .t)
            try container.encode(user, forKey: .user)
            try container.encode(role, forKey: .role)
        case .cursor(let pos):
            try container.encode("cursor", forKey: .t)
            if let pos {
                try container.encode(pos, forKey: .pos)
            } else {
                try container.encodeNil(forKey: .pos)
            }
        case .chat(let text, let bubble):
            try container.encode("chat", forKey: .t)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(bubble, forKey: .bubble)
        case .focus(let ws):
            try container.encode("focus", forKey: .t)
            if let ws {
                try container.encode(ws, forKey: .ws)
            } else {
                try container.encodeNil(forKey: .ws)
            }
        case .composeState(let field, let rev, let text, let carets):
            try container.encode("compose-state", forKey: .t)
            try container.encode(field, forKey: .field)
            try container.encode(rev, forKey: .rev)
            try container.encode(text, forKey: .text)
            try container.encode(carets, forKey: .carets)
        case .end:
            try container.encode("end", forKey: .t)
        }
    }
}

// MARK: - DO -> host

struct ShareSelfIdentity: Codable, Equatable, Sendable {
    var user: String
    var role: ShareRole
    var color: Int
    var isHost: Bool
}

struct ShareSessionSnapshot: Codable, Equatable, Sendable {
    var proto: Int
    var shared: [ShareSharedWorkspace]
    var layouts: [ShareWorkspaceLayout]
    var participants: [ShareParticipant]
    var chat: [ShareChatMessage]
    var you: ShareSelfIdentity
}

/// The subset of `ServerMessage` the host consumes. Unknown types decode to
/// `.unknown` so protocol additions never break an older host.
enum ShareServerMessage {
    case sessionState(ShareSessionSnapshot)
    case accessRequest(user: String, email: String)
    case presence(participants: [ShareParticipant])
    case cursor(user: String, pos: ShareCursorPos?)
    case chat(ShareChatMessage)
    case guestInput(user: String, ws: String, pane: String, data: String)
    case guestSub(ws: String, pane: String, count: Int)
    case guestCompose(user: String, field: String, rev: Int, ops: [ShareComposeOp], caret: ShareCaretRange?)
    case guestPointer(ShareGuestPointer)
    case guestWebKey(ShareGuestWebKey)
    case resync
    case sessionEnded(reason: String)
    case error(code: String, message: String)
    case unknown(type: String)
}

extension ShareServerMessage: Decodable {
    private enum CodingKeys: String, CodingKey {
        case t, user, email, participants, pos, msg, ws, pane, data, count, reason, code, message
        case field, rev, ops, caret
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .t)
        switch type {
        case "session-state":
            self = .sessionState(try ShareSessionSnapshot(from: decoder))
        case "access-request":
            self = .accessRequest(
                user: try container.decode(String.self, forKey: .user),
                email: try container.decode(String.self, forKey: .email)
            )
        case "presence":
            self = .presence(participants: try container.decode([ShareParticipant].self, forKey: .participants))
        case "cursor":
            self = .cursor(
                user: try container.decode(String.self, forKey: .user),
                pos: try container.decodeIfPresent(ShareCursorPos.self, forKey: .pos)
            )
        case "chat":
            self = .chat(try container.decode(ShareChatMessage.self, forKey: .msg))
        case "guest-input":
            self = .guestInput(
                user: try container.decode(String.self, forKey: .user),
                ws: try container.decode(String.self, forKey: .ws),
                pane: try container.decode(String.self, forKey: .pane),
                data: try container.decode(String.self, forKey: .data)
            )
        case "guest-sub":
            self = .guestSub(
                ws: try container.decode(String.self, forKey: .ws),
                pane: try container.decode(String.self, forKey: .pane),
                count: try container.decode(Int.self, forKey: .count)
            )
        case "guest-compose":
            self = .guestCompose(
                user: try container.decode(String.self, forKey: .user),
                field: try container.decode(String.self, forKey: .field),
                rev: try container.decode(Int.self, forKey: .rev),
                ops: try container.decode([ShareComposeOp].self, forKey: .ops),
                caret: try container.decodeIfPresent(ShareCaretRange.self, forKey: .caret)
            )
        case "guest-pointer":
            self = .guestPointer(try ShareGuestPointer(from: decoder))
        case "guest-webkey":
            self = .guestWebKey(try ShareGuestWebKey(from: decoder))
        case "resync":
            self = .resync
        case "session-ended":
            self = .sessionEnded(reason: try container.decode(String.self, forKey: .reason))
        case "error":
            self = .error(
                code: try container.decode(String.self, forKey: .code),
                message: try container.decode(String.self, forKey: .message)
            )
        default:
            self = .unknown(type: type)
        }
    }
}

// MARK: - Binary frames

/// Binary frame codec: `[kind u8][wsLen u8][ws utf8][paneLen u8][pane utf8][payload]`.
enum ShareBinaryFrame {
    static func encode(kind: UInt8, ws: String, pane: String, payload: Data) -> Data? {
        let wsBytes = Array(ws.utf8)
        let paneBytes = Array(pane.utf8)
        guard wsBytes.count <= 255, paneBytes.count <= 255 else { return nil }
        var out = Data(capacity: 3 + wsBytes.count + paneBytes.count + payload.count)
        out.append(kind)
        out.append(UInt8(wsBytes.count))
        out.append(contentsOf: wsBytes)
        out.append(UInt8(paneBytes.count))
        out.append(contentsOf: paneBytes)
        out.append(payload)
        return out
    }
}
