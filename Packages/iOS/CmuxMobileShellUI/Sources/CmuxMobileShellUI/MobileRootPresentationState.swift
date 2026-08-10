/// The single root-owned iOS sheet state and its presentation transitions.
///
/// Every case shares one SwiftUI sheet host. Replacing one non-`nil`
/// presentation with another therefore changes the sheet's content in place,
/// while setting it to `nil` dismisses that one host. Pairing can preempt the
/// migration introduction without acknowledging it because no queued modal or
/// second presenter is involved.
struct MobileRootPresentationState: Equatable {
    /// The content currently owned by the root sheet.
    enum Presentation: Equatable {
        case autoConnectMigrationIntroduction
        case connectionSettings
        case pairing(PairingPresentation)
    }

    /// Every presentation mutation accepted by the root coordinator.
    enum Action: Equatable {
        case presentAutoConnectMigrationIfIdle
        case continueWithAutoConnect
        case openConnectionSettings
        case presentPairing(PairingPresentation)
        case sheetDidRequestDismissal
        case dismissPairing
    }

    /// Side effects the owning view performs after a synchronous transition.
    enum Effect: Equatable {
        case none
        case acknowledgeAutoConnectMigration
        case finishPairing
    }

    /// The current sheet content, or `nil` when the root owns no modal.
    private(set) var presentation: Presentation? = nil

    /// Whether the one root sheet host should be presented.
    var isPresented: Bool {
        presentation != nil
    }

    /// Applies one shared presentation action and returns any required side effect.
    ///
    /// Interactive introduction dismissal acknowledges the migration. Pairing
    /// preemption only replaces the presentation, so a still-pending migration
    /// can be presented again after pairing leaves the sheet host.
    @discardableResult
    mutating func apply(_ action: Action) -> Effect {
        switch action {
        case .presentAutoConnectMigrationIfIdle:
            guard presentation == nil else { return .none }
            presentation = .autoConnectMigrationIntroduction
            return .none

        case .continueWithAutoConnect:
            guard presentation == .autoConnectMigrationIntroduction else { return .none }
            presentation = nil
            return .acknowledgeAutoConnectMigration

        case .openConnectionSettings:
            guard presentation == .autoConnectMigrationIntroduction else { return .none }
            presentation = .connectionSettings
            return .acknowledgeAutoConnectMigration

        case let .presentPairing(pairingPresentation):
            presentation = .pairing(pairingPresentation)
            return .none

        case .sheetDidRequestDismissal:
            switch presentation {
            case .autoConnectMigrationIntroduction:
                presentation = nil
                return .acknowledgeAutoConnectMigration
            case .pairing:
                presentation = nil
                return .finishPairing
            case .connectionSettings:
                presentation = nil
                return .none
            case nil:
                return .none
            }

        case .dismissPairing:
            guard case .pairing = presentation else { return .none }
            presentation = nil
            return .finishPairing
        }
    }
}
