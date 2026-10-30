import Foundation

nonisolated struct RustDropRequest: Encodable {
    var y: Double; var payload: RustPayload; var rows: [RustRow]; var sections: [RustSection]
    var ungroupedFirst: Bool; var groupEdgeFraction: Double; var groupExitFraction: Double; var sectionTopFraction: Double
    /// The middle band of a loose workspace row that drops onto it.
    var workspaceOntoStart: Double; var workspaceOntoEnd: Double
    enum CodingKeys: String, CodingKey {
        case y, payload, rows, sections; case ungroupedFirst = "ungrouped_first"; case groupEdgeFraction = "group_edge_fraction"; case groupExitFraction = "group_exit_fraction"; case sectionTopFraction = "section_top_fraction"
        case workspaceOntoStart = "workspace_onto_start"; case workspaceOntoEnd = "workspace_onto_end"
    }
}

/// `resolve_drag`: the card's centre and leading edge in displayed y, the
/// open gap, and the drop rules (Rust `sidebar_drag::DragRequest`).
nonisolated struct RustDragRequest: Encodable {
    var centreY: Double; var leadingY: Double; var gapY: Double?; var gapHeight: Double
    var payload: RustPayload; var rows: [RustRow]; var sections: [RustSection]
    var ungroupedFirst: Bool; var groupEdgeFraction: Double; var groupExitFraction: Double; var sectionTopFraction: Double
    var workspaceOntoStart: Double; var workspaceOntoEnd: Double
    enum CodingKeys: String, CodingKey {
        case centreY = "centre_y"; case leadingY = "leading_y"; case gapY = "gap_y"; case gapHeight = "gap_height"
        case payload, rows, sections; case ungroupedFirst = "ungrouped_first"; case groupEdgeFraction = "group_edge_fraction"; case groupExitFraction = "group_exit_fraction"; case sectionTopFraction = "section_top_fraction"
        case workspaceOntoStart = "workspace_onto_start"; case workspaceOntoEnd = "workspace_onto_end"
    }
}

nonisolated struct RustPayload: Encodable {
    var kind: String; var ids: [String]?; var id: String?
    init(_ payload: DragPayload) {
        switch payload { case let .workspaces(ids): kind = "workspaces"; self.ids = ids.map(\.rawValue); id = nil; case let .group(group): kind = "group"; ids = nil; id = group.rawValue
        case let .item(item): kind = "group"; ids = nil; id = "item:" + item } // never resolved here: only the document drags items
    }
}
