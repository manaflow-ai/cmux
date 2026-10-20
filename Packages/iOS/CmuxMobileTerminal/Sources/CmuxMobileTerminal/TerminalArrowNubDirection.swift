#if canImport(UIKit)
import CmuxMobileTerminalKit

enum TerminalArrowNubDirection {
    case up, down, left, right

    var repeatDirection: TerminalArrowRepeatService.Direction {
        switch self {
        case .up: return .upArrow
        case .down: return .downArrow
        case .right: return .rightArrow
        case .left: return .leftArrow
        }
    }

    var accessoryAction: TerminalInputAccessoryAction {
        switch self {
        case .up: return .upArrow
        case .down: return .downArrow
        case .right: return .rightArrow
        case .left: return .leftArrow
        }
    }
}
#endif
