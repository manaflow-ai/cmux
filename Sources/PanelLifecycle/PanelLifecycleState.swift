import Foundation

enum PanelLifecycleState: String, Codable, Sendable {
    case parked
    case awaitingAnchor
    case boundHidden
    case boundVisible
    case handoff
    case detaching
    case closed

    var debugName: String {
        rawValue
    }
}
