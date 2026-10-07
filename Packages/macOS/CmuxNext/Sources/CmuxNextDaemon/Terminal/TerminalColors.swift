import Foundation
import Synchronization
import os

/// Terminal colors captured with a replay or changed live. `nil` means "use
/// the frontend theme". Keys of `palette` are OSC 4 indexes.
public struct TerminalColors: Sendable, Hashable, Decodable {
    public struct Overrides: Sendable, Hashable, Decodable {
        public var fg: String?
        public var bg: String?
        public var cursor: String?
    }

    public var fg: String?
    public var bg: String?
    public var cursor: String?
    public var selectionBackground: String?
    public var selectionForeground: String?
    public var palette: [String: String]
    /// `"block" | "underline" | "bar"`. Apply after the replay: the replay omits DECSCUSR.
    public var cursorStyle: String?
    public var cursorBlink: Bool?
    /// App-authored OSC 10/11/12 state, distinct from session defaults.
    public var overrides: Overrides?

    enum CodingKeys: String, CodingKey {
        case fg, bg, cursor, palette, overrides
        case selectionBackground = "selection_bg"
        case selectionForeground = "selection_fg"
        case cursorStyle = "cursor_style"
        case cursorBlink = "cursor_blink"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fg = try c.decodeIfPresent(String.self, forKey: .fg)
        bg = try c.decodeIfPresent(String.self, forKey: .bg)
        cursor = try c.decodeIfPresent(String.self, forKey: .cursor)
        selectionBackground = try c.decodeIfPresent(String.self, forKey: .selectionBackground)
        selectionForeground = try c.decodeIfPresent(String.self, forKey: .selectionForeground)
        palette = try c.decodeIfPresent([String: String].self, forKey: .palette) ?? [:]
        cursorStyle = try c.decodeIfPresent(String.self, forKey: .cursorStyle)
        cursorBlink = try c.decodeIfPresent(Bool.self, forKey: .cursorBlink)
        overrides = try c.decodeIfPresent(Overrides.self, forKey: .overrides)
    }
}

public struct KittyImageAlias: Sendable, Hashable, Decodable {
    public var imageID: UInt32
    public var imageNumber: UInt32
    enum CodingKeys: String, CodingKey {
        case imageID = "image_id"
        case imageNumber = "image_number"
    }
}

/// Kitty graphics sidecar of a daemon replay (the desktop fork restored it
/// with a kitty replay API; GhosttyNextKit restores images through snapshots).
public struct KittyGraphicsState: Sendable, Hashable, Decodable {
    public var imageBytes: UInt64
    public var inflightBytes: UInt64
    public var images: UInt64
    public var placements: UInt64
    /// Feed `data[..<offset]`, install the replay cursors, then feed the rest.
    public var replayCursorOffset: UInt32
    public var primaryReplayNextImageID: UInt32
    public var primaryNextImageID: UInt32
    public var alternateReplayNextImageID: UInt32
    public var alternateNextImageID: UInt32

    enum CodingKeys: String, CodingKey {
        case images, placements
        case imageBytes = "image_bytes"
        case inflightBytes = "inflight_bytes"
        case replayCursorOffset = "replay_cursor_offset"
        case primaryReplayNextImageID = "primary_replay_next_image_id"
        case primaryNextImageID = "primary_next_image_id"
        case alternateReplayNextImageID = "alternate_replay_next_image_id"
        case alternateNextImageID = "alternate_next_image_id"
    }
}
