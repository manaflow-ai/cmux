/// The Chief profile panel's tabs (Lawrence's reference, 2026-11-04, after Grok's bot panel): every
/// Chief setting lives in exactly one of them. Details is who the Chief is and where it runs,
/// Settings is how it works and looks, Computer is its computer.
public nonisolated enum HomeChiefProfileTab: String, CaseIterable, Sendable {
    case details, settings, computer

    @MainActor var title: String {
        switch self {
        case .details: HomeEngineStrings.tabDetails
        case .settings: HomeEngineStrings.tabSettings
        case .computer: HomeEngineStrings.tabComputer
        }
    }
}
