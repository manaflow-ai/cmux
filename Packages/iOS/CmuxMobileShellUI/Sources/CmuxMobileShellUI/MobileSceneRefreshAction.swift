import SwiftUI

enum MobileSceneRefreshAction: Equatable {
    case none
    case enterBackground
    case resumeForeground

    static func forScenePhase(_ phase: ScenePhase) -> Self {
        switch phase {
        case .active: .resumeForeground
        case .background: .enterBackground
        case .inactive: .none
        @unknown default: .none
        }
    }
}
