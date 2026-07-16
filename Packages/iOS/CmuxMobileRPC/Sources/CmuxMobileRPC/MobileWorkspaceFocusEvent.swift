public import Foundation

/// A workspace-scoped focus snapshot carried by `workspace.updated`.
public struct MobileWorkspaceFocusEvent: Decodable, Sendable {
    /// Stable Mac-local workspace identity.
    public let workspaceID: String
    /// Focused pane identity, or `nil` when the host has no focused pane.
    public let focusedPaneID: String?
    /// Selected terminal identity, or `nil` when a non-terminal tab is selected.
    public let selectedTerminalID: String?
    /// Host-lifetime ordering token. Missing for hosts that predate sequenced
    /// focus events; the shell accepts that legacy mode until a token is seen.
    public let sequence: UInt64?

    private enum CodingKeys: String, CodingKey {
        case kind
        case workspaceID = "workspace_id"
        case focusedPaneID = "focused_pane_id"
        case selectedTerminalID = "selected_terminal_id"
        case sequence = "seq"
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
        sequence = try values.decodeIfPresent(UInt64.self, forKey: .sequence)
    }

    /// Decodes a focus event, returning `nil` for legacy/global payloads.
    public init?(payloadJSON data: Data?) {
        guard let data else { return nil }
        guard let decoded = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        self = decoded
    }
}
