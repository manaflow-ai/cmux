public import Foundation

/// One panel's health row for the v1 `surface_health` listing.
public struct ControlSidebarSurfaceHealthRow: Sendable, Equatable {
    /// Per-panel-kind health details.
    public enum Kind: Sendable, Equatable {
        /// A terminal panel with view-hosting diagnostics.
        case terminal(inWindow: Bool, portalHosted: Bool, viewDepth: Int)
        /// A browser panel with window attachment.
        case browser(inWindow: Bool)
        /// Any other panel kind (`in_window=unknown`).
        case other
    }

    /// The panel id.
    public let panelID: UUID
    /// The panel type raw value.
    public let typeRawValue: String
    /// The per-kind health details.
    public let kind: Kind

    /// Creates a row.
    ///
    /// - Parameters:
    ///   - panelID: The panel id.
    ///   - typeRawValue: The panel type raw value.
    ///   - kind: The per-kind health details.
    public init(panelID: UUID, typeRawValue: String, kind: Kind) {
        self.panelID = panelID
        self.typeRawValue = typeRawValue
        self.kind = kind
    }
}
