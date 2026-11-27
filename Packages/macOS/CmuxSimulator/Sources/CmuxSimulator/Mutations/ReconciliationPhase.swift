enum ReconciliationPhase: String, Codable {
    case suppressingLegacy
    case migratedLegacy
    case preservingDurable
    case corruptionBlocked
}
