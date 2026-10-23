import CmuxNextDaemonService
import CmuxNextLayout

extension RefusalStrings {
    /// A direction word for "no pane left of ..." style reasons. It lives where CmuxNextLayout is
    /// visible: CmuxNextDaemonService (a service) does not depend on the Layout UI target.
    nonisolated static func direction(_ direction: LayoutDirection) -> String {
        switch direction {
        case .left: directionLeft
        case .right: directionRight
        case .up: directionUp
        case .down: directionDown
        }
    }
}
