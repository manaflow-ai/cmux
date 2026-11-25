import CmuxNextHomeModel
import MessagesLabHome

/// The Home transcript's MessagesLab styles of the Debug Settings choices (``HomeTunables``).
nonisolated extension HomeTurnProgressChoice {
    var style: HomeTurnProgressStyle {
        switch self {
        case .narrated: .narrated
        case .steps: .steps
        case .line: .line
        }
    }
}

nonisolated extension HomeTopFadeChoice {
    var style: HomeTopFadeStyle {
        switch self {
        case .glassBand: .glassBand
        case .softMask: .softMask
        case .progressiveBlur: .progressiveBlur
        case .materialHairline: .materialHairline
        case .edgeShadow: .edgeShadow
        case .belowPill: .belowPill
        case .backgroundTint: .backgroundTint
        case .messagesBar: .messagesBar
        }
    }
}
