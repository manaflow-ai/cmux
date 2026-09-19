/// Optional enrichment of the fixed local-machine process census.
struct CmuxTopProcessFields: OptionSet, Sendable {
    let rawValue: UInt8
    static let details = Self(rawValue: 1)
    static let scope = Self(rawValue: 2)
    init(rawValue: UInt8) { self.rawValue = rawValue }
    init(details: Bool, scope: Bool) {
        self = []
        if details { insert(.details) }
        if scope { insert(.scope) }
    }
}
