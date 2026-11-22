import Foundation

nonisolated struct RustTabRequest: Encodable {
    var y: Double; var rows: [RustRow]; var sections: [RustSection]; var sourceMachine: String?
    var groupEdgeFraction: Double; var groupExitFraction: Double; var sectionTopFraction: Double; var tabIntoStart: Double; var tabIntoEnd: Double
    enum CodingKeys: String, CodingKey {
        case y, rows, sections; case sourceMachine = "source_machine"; case groupEdgeFraction = "group_edge_fraction"; case groupExitFraction = "group_exit_fraction"; case sectionTopFraction = "section_top_fraction"; case tabIntoStart = "tab_into_start"; case tabIntoEnd = "tab_into_end"
    }
}
