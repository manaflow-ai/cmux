/// Line draws the outline form; Solid is the filled form for selected or
/// dense rows.
public nonisolated enum IconStyle: String, Hashable, Sendable, Codable, CaseIterable {
    case line
    case solid
}
