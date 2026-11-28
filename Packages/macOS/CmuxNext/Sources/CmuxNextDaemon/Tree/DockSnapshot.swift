import Foundation

// DockSnapshot and its enums are generated from the schema's `ColumnDock` (swift_app codegen, Tree
// family); the nested names stay for the app's call sites.
extension DockSnapshot {
    public typealias Edge = ColumnDockEdge
    public typealias Mode = ColumnDockMode
    public typealias Role = ColumnDockRole
}

extension ColumnDockEdge {
    public var isBand: Bool { self == .top || self == .bottom }
}
