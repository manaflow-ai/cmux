import Foundation
import GhosttyKit

// MARK: - Connection Lifecycle

/// States of a tmux control mode connection (spec SS3).
enum TmuxConnectionState: String, Sendable {
    /// DCS detected, waiting for handshake
    case connecting
    /// Version detection, capability exchange
    case negotiating
    /// Initial window/pane data loading
    case synchronizing
    /// Steady state operation
    case connected
    /// Clean detach in progress
    case disconnecting
    /// Fully torn down
    case disconnected
}

// MARK: - Events from Ghostty Viewer

/// Events dispatched from the Ghostty Viewer via the C API action callback.
/// Maps to `ghostty_tmux_event_e` values.
enum TmuxEvent: Sendable {
    case enter
    case exit
    case windowsChanged(TmuxWindowsPayload)
    case paneOutput(paneId: UInt32, data: Data)
    case layoutChange(windowId: UInt32, layoutJSON: Data)
    case windowAdd(windowId: UInt32)
    case windowClose(windowId: UInt32)
    case windowRenamed(windowId: UInt32, name: String)
    case sessionChanged(sessionId: UInt32, name: String)
    case sessionRenamed(name: String)

    /// Parse a `ghostty_action_tmux_control_s` into a `TmuxEvent`.
    /// Returns nil if the event type is unrecognized.
    static func from(_ action: ghostty_action_tmux_control_s) -> TmuxEvent? {
        let data: Data
        if action.data_len > 0, let ptr = action.data {
            data = Data(bytes: ptr, count: Int(action.data_len))
        } else {
            data = Data()
        }

        switch action.event {
        case GHOSTTY_TMUX_ENTER:
            return .enter
        case GHOSTTY_TMUX_EXIT:
            return .exit
        case GHOSTTY_TMUX_WINDOWS_CHANGED:
            guard let payload = try? JSONDecoder().decode(TmuxWindowsPayload.self, from: data) else {
                return nil
            }
            return .windowsChanged(payload)
        case GHOSTTY_TMUX_PANE_OUTPUT:
            return .paneOutput(paneId: action.id, data: data)
        case GHOSTTY_TMUX_LAYOUT_CHANGE:
            return .layoutChange(windowId: action.id, layoutJSON: data)
        case GHOSTTY_TMUX_WINDOW_ADD:
            return .windowAdd(windowId: action.id)
        case GHOSTTY_TMUX_WINDOW_CLOSE:
            return .windowClose(windowId: action.id)
        case GHOSTTY_TMUX_WINDOW_RENAMED:
            let name = String(data: data, encoding: .utf8) ?? ""
            return .windowRenamed(windowId: action.id, name: name)
        case GHOSTTY_TMUX_SESSION_CHANGED:
            let name = String(data: data, encoding: .utf8) ?? ""
            return .sessionChanged(sessionId: action.id, name: name)
        case GHOSTTY_TMUX_SESSION_RENAMED:
            let name = String(data: data, encoding: .utf8) ?? ""
            return .sessionRenamed(name: name)
        default:
            return nil
        }
    }
}

// MARK: - Windows Payload (JSON from Zig)

/// Decoded from the JSON payload of a `windows_changed` event.
/// Matches the JSON produced by `serializeTmuxWindows` in stream_handler.zig.
struct TmuxWindowsPayload: Codable, Sendable {
    let sessionId: Int
    let tmuxVersion: String
    let windows: [TmuxWindow]

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case tmuxVersion = "tmux_version"
        case windows
    }
}

/// A single tmux window with its layout tree.
struct TmuxWindow: Codable, Sendable {
    let id: Int
    let width: Int
    let height: Int
    let layout: TmuxLayoutNode
}

// MARK: - Layout Tree

/// Recursive layout tree node. Matches the Zig `Layout` JSON serialization
/// which flattens width/height/x/y + content discriminator into one object.
///
/// Example JSON:
/// ```json
/// {"width":80,"height":24,"x":0,"y":0,"pane":0}
/// {"width":80,"height":24,"x":0,"y":0,"horizontal":[...]}
/// ```
indirect enum TmuxLayoutNode: Sendable {
    case pane(TmuxLayoutLeaf)
    case horizontal(TmuxLayoutSplit)
    case vertical(TmuxLayoutSplit)
}

/// A leaf node representing a single tmux pane.
struct TmuxLayoutLeaf: Codable, Sendable {
    let paneId: Int
    let width: Int
    let height: Int
    let x: Int
    let y: Int
}

/// A split node containing child layout nodes.
struct TmuxLayoutSplit: Codable, Sendable {
    let width: Int
    let height: Int
    let x: Int
    let y: Int
    let children: [TmuxLayoutNode]
}

// MARK: - TmuxLayoutNode Codable

extension TmuxLayoutNode: Codable {
    private enum ContentKey: String, CodingKey {
        case width, height, x, y
        case pane, horizontal, vertical
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ContentKey.self)
        let width = try container.decode(Int.self, forKey: .width)
        let height = try container.decode(Int.self, forKey: .height)
        let x = try container.decode(Int.self, forKey: .x)
        let y = try container.decode(Int.self, forKey: .y)

        if let paneId = try container.decodeIfPresent(Int.self, forKey: .pane) {
            self = .pane(TmuxLayoutLeaf(
                paneId: paneId, width: width, height: height, x: x, y: y
            ))
        } else if let children = try container.decodeIfPresent([TmuxLayoutNode].self, forKey: .horizontal) {
            self = .horizontal(TmuxLayoutSplit(
                width: width, height: height, x: x, y: y, children: children
            ))
        } else if let children = try container.decodeIfPresent([TmuxLayoutNode].self, forKey: .vertical) {
            self = .vertical(TmuxLayoutSplit(
                width: width, height: height, x: x, y: y, children: children
            ))
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Layout node must have pane, horizontal, or vertical key"
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: ContentKey.self)
        switch self {
        case .pane(let leaf):
            try container.encode(leaf.width, forKey: .width)
            try container.encode(leaf.height, forKey: .height)
            try container.encode(leaf.x, forKey: .x)
            try container.encode(leaf.y, forKey: .y)
            try container.encode(leaf.paneId, forKey: .pane)
        case .horizontal(let split):
            try container.encode(split.width, forKey: .width)
            try container.encode(split.height, forKey: .height)
            try container.encode(split.x, forKey: .x)
            try container.encode(split.y, forKey: .y)
            try container.encode(split.children, forKey: .horizontal)
        case .vertical(let split):
            try container.encode(split.width, forKey: .width)
            try container.encode(split.height, forKey: .height)
            try container.encode(split.x, forKey: .x)
            try container.encode(split.y, forKey: .y)
            try container.encode(split.children, forKey: .vertical)
        }
    }
}

// MARK: - Version-Gated Capabilities (spec SS14)

/// Feature capabilities gated by the connected tmux server version.
struct TmuxCapabilities {
    private let versionCheck: (String) -> Bool

    init(versionCheck: @escaping (String) -> Bool) {
        self.versionCheck = versionCheck
    }

    /// Pause mode (tmux >= 3.2): `refresh-client -f pause-after=N`
    var supportsPauseMode: Bool { versionCheck("3.2") }

    /// Variable window sizes (tmux >= 2.9): `resize-window`
    var supportsVariableWindowSize: Bool { versionCheck("2.9") }

    /// Per-window refresh-client (tmux >= 3.4): `refresh-client -C @wid:WxH`
    var supportsPerWindowRefreshClient: Bool { versionCheck("3.4") }

    /// Subscriptions for pane title changes (tmux >= 3.2)
    var supportsSubscriptions: Bool { versionCheck("3.2") }
}

// MARK: - Session Persistence

/// Metadata persisted in session snapshots for tmux workspaces.
/// On restore, this is used to automatically reconnect to the tmux session.
struct TmuxSessionInfo: Codable, Sendable {
    /// The tmux session name (e.g., "main").
    var sessionName: String

    /// The command to reconnect (e.g., "tmux -CC attach -t main").
    var connectionCommand: String
}

// MARK: - Layout Node Helpers

extension TmuxLayoutNode {
    /// Width of this layout node.
    var width: Int {
        switch self {
        case .pane(let leaf): leaf.width
        case .horizontal(let split): split.width
        case .vertical(let split): split.width
        }
    }

    /// Height of this layout node.
    var height: Int {
        switch self {
        case .pane(let leaf): leaf.height
        case .horizontal(let split): split.height
        case .vertical(let split): split.height
        }
    }

    /// Collect all pane IDs in this layout subtree.
    var allPaneIds: [Int] {
        switch self {
        case .pane(let leaf):
            return [leaf.paneId]
        case .horizontal(let split), .vertical(let split):
            return split.children.flatMap(\.allPaneIds)
        }
    }
}
