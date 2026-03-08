import Foundation

enum PanelResidency: String, Codable, Sendable {
    case visibleInActiveWindow
    case parkedOffscreen
    case detachedRetained
    case destroyed

    var debugName: String {
        rawValue
    }
}

enum PanelResidencyPolicy: String, Codable, Sendable {
    case persistent
    case parked
    case regenerable
}

enum PanelInteractionModel: String, Codable, Sendable {
    case interactive
    case readOnly
}

enum PanelBackgroundWorkPolicy: String, Codable, Sendable {
    case hiddenAllowed
    case hiddenLimited
    case hiddenRebuild
}

enum PanelFocusPolicy: String, Codable, Sendable {
    case firstResponder
    case none
}

enum PanelAccessibilityPolicy: String, Codable, Sendable {
    case activeVisibleTree
    case noneWhenHidden
}

struct PanelLifecycleBackendProfile: Codable, Sendable {
    let panelType: PanelType
    let residencyPolicy: PanelResidencyPolicy
    let interactionModel: PanelInteractionModel
    let backgroundWorkPolicy: PanelBackgroundWorkPolicy
    let focusPolicy: PanelFocusPolicy
    let accessibilityPolicy: PanelAccessibilityPolicy
}
