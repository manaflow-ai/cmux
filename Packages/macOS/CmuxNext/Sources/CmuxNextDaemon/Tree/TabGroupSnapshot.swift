import Foundation

/// `TabGroupSnapshot` itself is generated from the schema's `TabGroupRun` (swift_app/bindings.json, Tree family).
extension TabGroupSnapshot {
    /// Member count; the wire's `count` always equals `surfaces.count`.
    public var count: Int { surfaces.count }

    /// Members as `TabGroupMember`s (the pre-15518 shape).
    public var tabs: [TabGroupMember] { surfaces.map(TabGroupMember.surface) }
}

/// A group member, named by numeric surface or durable tab resource id.
public enum TabGroupMember: Sendable, Hashable, Decodable {
    case surface(SurfaceID)
    case tab(ResourceID)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let surface = try? container.decode(UInt64.self) {
            self = .surface(SurfaceID(rawValue: surface))
        } else {
            self = .tab(ResourceID(rawValue: try container.decode(String.self)))
        }
    }

    /// True when this member names `tab`.
    public func matches(_ tab: TabSnapshot) -> Bool {
        switch self {
        case .surface(let surface): surface == tab.surface
        case .tab(let resource): resource == tab.tabResourceID
        }
    }
}
