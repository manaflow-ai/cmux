internal import Foundation

extension ControlCommandCoordinator {
    enum HelperVisiblePlacement {
        case reuse(ControlPaneSummary, ControlSurfaceHealthEntry)
        case blockedInvisible(ControlPaneSummary)
        case create
    }
}
