import Foundation

enum PendingManualHostTrust {
    case manual(
        attemptID: UUID,
        name: String,
        host: String,
        port: Int,
        pairedMacDeviceID: String?,
        recordsPairingAttempt: Bool,
        macSwitchAttemptID: UUID?,
        ifStillCurrent: (() -> Bool)?
    )
    case pairingURL(attemptID: UUID, rawURL: String, acceptedVersionWarning: Bool)

    var attemptID: UUID {
        switch self {
        case let .manual(attemptID, _, _, _, _, _, _, _):
            attemptID
        case let .pairingURL(attemptID, _, _):
            attemptID
        }
    }

    var macSwitchAttemptID: UUID? {
        switch self {
        case let .manual(_, _, _, _, _, _, macSwitchAttemptID, _):
            macSwitchAttemptID
        case .pairingURL:
            nil
        }
    }

    var ifStillCurrent: (() -> Bool)? {
        switch self {
        case let .manual(_, _, _, _, _, _, _, ifStillCurrent):
            ifStillCurrent
        case .pairingURL:
            nil
        }
    }
}
