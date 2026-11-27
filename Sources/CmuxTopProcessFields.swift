/// Optional enrichment of the fixed local-machine process census.
struct CmuxTopProcessFields: OptionSet, Sendable {
    let rawValue: UInt8
    static let details = Self(rawValue: 1)
    static let scope = Self(rawValue: 2)
    static let resources = Self(rawValue: 4)
    init(rawValue: UInt8) { self.rawValue = rawValue }
    init(details: Bool, scope: Bool, resources: Bool) {
        self = []
        if details { insert(.details) }
        if scope { insert(.scope) }
        if resources { insert(.resources) }
    }
}
