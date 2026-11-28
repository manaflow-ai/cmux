package import Foundation

/// What a hibernated item keeps while it sleeps: a row of facts, not a live object. Its last frame is a
/// file in a ``HibernationSnapshots`` store (on disk, under that store's budget), and the record names
/// it by the item's key; nothing else of the item stays in memory. Showing the item rebuilds it from its
/// owner (acpmux for a chat, the page's history for a browser tab) and draws the frame until it paints.
///
/// Leo, 2026-11-22 (goals/infinite-tabs-flat.md): "i also want us to keep pursuing the ability to have infinite
/// f***ing tabs and workspaces and shit without getting starved of cpu/ram". 100 hidden agent chats each kept
/// their last frame as an encoded image in app memory (`AgentPaneLaunchImages`, a PNG for a capture with alpha:
/// about 0.5 to 2 MB a chat at 2x, with no bound); the browser tabs' pictures had already moved to disk.
///
/// One shape for every kind, so what else puts an item to sleep (a workspace, a browser tab, a chat offloaded
/// to another machine, a paused Chief machine) writes the same row: `kind`, `key`, the `machine` it lives on,
/// and its frame's point size and light or dark look. It is Codable for a reader outside the app (the daemon,
/// another Mac); the app keeps it for this launch only (the frames' store is a temporary directory), so a
/// relaunch rebuilds the item from its owner and loses no work.
package nonisolated struct DormantRecord: Codable, Sendable, Equatable {
    /// The record's layout (persisted-formats/formats.toml, policy rebuild).
    package static let recordVersion = 1

    /// What sleeps.
    package enum Kind: String, Codable, Sendable {
        case agentChat = "agent_chat"
        case browserTab = "browser_tab"
        case workspace
    }

    package var version: Int
    package var kind: Kind
    /// The item's key in its store (a chat's launch-image slot, a browser tab's key, a workspace id).
    package var key: String
    /// The machine the item lives on; nil for this Mac.
    package var machine: String?
    /// The frame's size in points (its pixels are this times its scale).
    package var width: Double
    package var height: Double
    /// `NSAppearance.Name` raw value the frame was taken in (light or dark); nil when unknown.
    package var appearance: String?
    /// Encoded frame bytes on disk, the store's cost for it.
    package var frameBytes: Int

    package init(kind: Kind, key: String, machine: String? = nil, width: Double, height: Double, appearance: String?, frameBytes: Int) {
        version = Self.recordVersion
        self.kind = kind
        self.key = key
        self.machine = machine
        self.width = width
        self.height = height
        self.appearance = appearance
        self.frameBytes = frameBytes
    }
}
