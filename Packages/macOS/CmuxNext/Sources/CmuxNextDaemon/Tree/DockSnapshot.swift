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

/// The dock a request asks for (`move-tab-to-column {dock}`, `new-conversation-tab {dock}`): edge, mode, role, and
/// `pinned` only when set (`pinned-dock-alone-v1`: only a pinned dock may take a screen's only tab, Home's dock).
/// Hand-written: the generated type only decodes, and a request must not send `allow_tabs` or `pinned: false`.
extension DockSnapshot: Encodable {
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(edge.rawValue, forKey: .edge)
        try c.encode(mode.rawValue, forKey: .mode)
        try c.encodeIfPresent(role?.rawValue, forKey: .role)
        if isPinned { try c.encode(true, forKey: .isPinned) }
    }
}
