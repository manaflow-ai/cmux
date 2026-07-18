enum MobileToastLifetime: Equatable, Sendable {
    case brief
    case standard
    case long
    case persistent

    func duration(voiceOverEnabled: Bool) -> Duration? {
        let baseDuration: Duration?
        switch self {
        case .brief:
            baseDuration = .milliseconds(2_800)
        case .standard:
            baseDuration = .seconds(6)
        case .long:
            baseDuration = .seconds(8)
        case .persistent:
            baseDuration = nil
        }

        guard voiceOverEnabled, let baseDuration else { return baseDuration }
        return baseDuration * 2
    }
}
