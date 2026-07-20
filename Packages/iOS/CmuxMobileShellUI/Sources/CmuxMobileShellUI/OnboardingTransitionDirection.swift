#if os(iOS)
import SwiftUI

enum OnboardingTransitionDirection: Equatable, Sendable {
    case forward
    case backward

    init(from current: OnboardingStage, to destination: OnboardingStage) {
        self = destination.position > current.position ? .forward : .backward
    }

    var pushEdge: Edge {
        switch self {
        case .forward: .trailing
        case .backward: .leading
        }
    }
}
#endif
