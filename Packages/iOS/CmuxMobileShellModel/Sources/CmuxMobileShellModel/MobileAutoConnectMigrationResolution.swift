/// The durable outcome of the versioned Auto-Connect migration introduction.
public enum MobileAutoConnectMigrationResolution: String, CaseIterable, Equatable, Sendable {
    /// This installation qualified at launch and still needs the introduction.
    case pending
    /// This installation did not qualify and must never receive this version.
    case ineligible
    /// The user explicitly dismissed or acted on the introduction.
    case acknowledged
}
