public import CmuxNextDesign
import MessagesLabHome

/// ``HomeTunables/topFadeStyle``'s choices: MessagesLabHome's ``HomeTopFadeStyle``, one to one.
public nonisolated enum HomeTopFadeChoice: String, Sendable, CaseIterable, TunableChoice {
    case glassBand
    case softMask
    case progressiveBlur
    case materialHairline
    case edgeShadow
    case belowPill
    case backgroundTint
    case messagesBar

    public var tunableTitle: String {
        switch self {
        case .glassBand: "A. Glass band"
        case .softMask: "B. Soft tall fade"
        case .progressiveBlur: "C. Progressive blur"
        case .materialHairline: "D. Material band, hairline"
        case .edgeShadow: "E. Hard edge, shadow when scrolled"
        case .belowPill: "F. Fade below the pill"
        case .backgroundTint: "G. Background tint (default)"
        case .messagesBar: "H. Messages blurred bar"
        }
    }

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
