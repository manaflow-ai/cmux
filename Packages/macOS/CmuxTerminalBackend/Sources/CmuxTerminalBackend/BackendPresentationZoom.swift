/// Presentation-local pane zoom that never mutates canonical topology.
public struct BackendPresentationZoom: Codable, Equatable, Sendable {
    /// The zoomed pane, or `nil` when the presentation is not zoomed.
    public let paneID: PaneID?

    /// Creates presentation-local pane zoom state.
    ///
    /// - Parameter paneID: The zoomed pane, or `nil` for no zoom.
    public init(paneID: PaneID? = nil) {
        self.paneID = paneID
    }

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_uuid"
    }

    var jsonValue: BackendJSONValue {
        .object(["pane_uuid": paneID.map { .string($0.description) } ?? .null])
    }
}
