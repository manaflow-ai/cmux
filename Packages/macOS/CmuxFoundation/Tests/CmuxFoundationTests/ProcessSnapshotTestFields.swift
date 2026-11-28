struct ProcessSnapshotTestFields: OptionSet, Sendable {
    let rawValue: Int
    static let paths = Self(rawValue: 1)
    static let scope = Self(rawValue: 2)
}
