enum CmuxConfigActionCatalogRawFileStatus: UInt8, Sendable, Equatable {
    case missing = 0
    case data = 1
    case unreadable = 2
    case tooLarge = 3
}
