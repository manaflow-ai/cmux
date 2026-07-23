extension CMUXActionCatalogReadHelper {
    enum FieldStatus: UInt8 {
        case missing = 0
        case data = 1
        case unreadable = 2
        case tooLarge = 3
    }
}
