public import Foundation

/// A workspace-scoped focus snapshot carried by `workspace.updated`.
public struct MobileWorkspaceFocusEvent: Decodable, Sendable {
    /// Stable Mac-local workspace identity.
    public let workspaceID: String
    /// Focused pane identity, or `nil` when the host has no focused pane.
    public let focusedPaneID: String?
    /// Selected terminal identity, or `nil` when a non-terminal tab is selected.
    public let selectedTerminalID: String?

    private enum CodingKeys: String, CodingKey {
        case kind
        case workspaceID = "workspace_id"
        case focusedPaneID = "focused_pane_id"
        case selectedTerminalID = "selected_terminal_id"
    }

    /// Decodes only the focus-specific `workspace.updated` payload variant.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(String.self, forKey: .kind) == "focus" else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: values,
                debugDescription: "Expected a workspace focus event"
            )
        }
        workspaceID = try values.decode(String.self, forKey: .workspaceID)
        focusedPaneID = try values.decodeIfPresent(String.self, forKey: .focusedPaneID)
        selectedTerminalID = try values.decodeIfPresent(String.self, forKey: .selectedTerminalID)
    }

    /// Decodes a focus event, returning `nil` for legacy/global payloads.
    public init?(payloadJSON data: Data?) {
        guard let data else { return nil }
        guard let decoded = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        self = decoded
    }
}
