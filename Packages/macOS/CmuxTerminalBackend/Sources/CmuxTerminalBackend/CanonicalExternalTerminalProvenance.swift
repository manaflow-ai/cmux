public import Foundation

/// Durable, non-secret origin metadata for one parser-only terminal surface.
///
/// Connection details are deliberately excluded. A frontend uses `producerID`
/// to claim those private details over an authenticated connection.
public struct CanonicalExternalTerminalProvenance: Codable, Equatable, Sendable {
    /// The external runtime that produces terminal bytes.
    public enum ProducerKind: String, Codable, Equatable, Sendable {
        case remoteTmux = "remote-tmux"
    }

    /// How the surface participates in the frontend's remote tmux projection.
    public enum PresentationRole: String, Codable, Equatable, Sendable {
        /// The surface is the outer tab representing one tmux window.
        case workspaceTab = "workspace-tab"

        /// The surface is hosted inside the outer tmux-window presentation.
        case nestedPane = "nested-pane"
    }

    public let producerKind: ProducerKind
    public let producerID: UUID
    public let tmuxSessionID: UInt64
    public let tmuxWindowID: UInt64
    public let tmuxPaneID: UInt64
    public let presentationRole: PresentationRole

    public init(
        producerKind: ProducerKind = .remoteTmux,
        producerID: UUID,
        tmuxSessionID: UInt64,
        tmuxWindowID: UInt64,
        tmuxPaneID: UInt64,
        presentationRole: PresentationRole
    ) {
        self.producerKind = producerKind
        self.producerID = producerID
        self.tmuxSessionID = tmuxSessionID
        self.tmuxWindowID = tmuxWindowID
        self.tmuxPaneID = tmuxPaneID
        self.presentationRole = presentationRole
    }

    internal var jsonValue: BackendJSONValue {
        .object([
            "producer_kind": .string(producerKind.rawValue),
            "producer_id": .string(producerID.uuidString.lowercased()),
            "tmux_session_id": .unsignedInteger(tmuxSessionID),
            "tmux_window_id": .unsignedInteger(tmuxWindowID),
            "tmux_pane_id": .unsignedInteger(tmuxPaneID),
            "presentation_role": .string(presentationRole.rawValue),
        ])
    }

    private enum CodingKeys: String, CodingKey {
        case producerKind = "producer_kind"
        case producerID = "producer_id"
        case tmuxSessionID = "tmux_session_id"
        case tmuxWindowID = "tmux_window_id"
        case tmuxPaneID = "tmux_pane_id"
        case presentationRole = "presentation_role"
    }
}
