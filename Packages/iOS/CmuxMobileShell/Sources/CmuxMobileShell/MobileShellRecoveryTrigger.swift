extension MobileShellComposite {
    enum RecoveryTrigger: CustomStringConvertible {
        case availabilityFailure
        case eventStreamEnded
        case liveness
        case networkChange
        case manual
        case presencePush

        var reschedulesSecondaryAggregation: Bool { self != .presencePush }
        var resetsConnectedSession: Bool { self != .presencePush }

        var description: String {
            switch self {
            case .availabilityFailure: return "availabilityFailure"
            case .eventStreamEnded: return "eventStreamEnded"
            case .liveness: return "liveness"
            case .networkChange: return "networkChange"
            case .manual: return "manual"
            case .presencePush: return "presencePush"
            }
        }
    }
}
