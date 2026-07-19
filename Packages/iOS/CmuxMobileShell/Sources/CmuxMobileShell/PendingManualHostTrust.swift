import CMUXMobileCore
import Foundation

enum PendingManualHostTrust {
    case manual(
        attemptID: UUID,
        name: String,
        host: String,
        port: Int,
        route: CmxAttachRoute,
        pairedMacDeviceID: String?,
        instanceTagExpectation: MobileMacInstanceTagExpectation,
        recordsPairingAttempt: Bool,
        macSwitchAttemptID: UUID?,
        ifStillCurrent: (() -> Bool)?
    )
    case pairingURL(
        attemptID: UUID,
        rawURL: String,
        acceptedVersionWarning: Bool,
        approvedRouteID: String?
    )

    var attemptID: UUID {
        switch self {
        case let .manual(attemptID, _, _, _, _, _, _, _, _, _):
            attemptID
        case let .pairingURL(attemptID, _, _, _):
            attemptID
        }
    }

    var macSwitchAttemptID: UUID? {
        switch self {
        case let .manual(_, _, _, _, _, _, _, _, macSwitchAttemptID, _):
            macSwitchAttemptID
        case .pairingURL:
            nil
        }
    }

    var ifStillCurrent: (() -> Bool)? {
        switch self {
        case let .manual(_, _, _, _, _, _, _, _, _, ifStillCurrent):
            ifStillCurrent
        case .pairingURL:
            nil
        }
    }

    var pairedMacDeviceID: String? {
        switch self {
        case let .manual(_, _, _, _, _, pairedMacDeviceID, _, _, _, _):
            pairedMacDeviceID
        case .pairingURL:
            nil
        }
    }

    func approving(route: CmxAttachRoute) -> PendingManualHostTrust {
        switch self {
        case .manual:
            self
        case let .pairingURL(attemptID, rawURL, acceptedVersionWarning, _):
            .pairingURL(
                attemptID: attemptID,
                rawURL: rawURL,
                acceptedVersionWarning: acceptedVersionWarning,
                approvedRouteID: route.id
            )
        }
    }
}
