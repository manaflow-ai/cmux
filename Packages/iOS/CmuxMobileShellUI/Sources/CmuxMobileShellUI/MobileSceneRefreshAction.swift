import SwiftUI

nonisolated enum MobileSceneRefreshAction: Equatable {
    case none
    case enterBackground
    case resumeForeground

    init(scenePhase: ScenePhase) {
        self = switch scenePhase {
        case .active: .resumeForeground
        case .background: .enterBackground
        case .inactive: .none
        @unknown default: .none
        }
    }
}
