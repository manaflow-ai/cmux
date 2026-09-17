public struct MobileSimulatorListParameters: Codable, Equatable, Sendable {
    public let workspaceID: String?

    public init(workspaceID: String? = nil) {
        self.workspaceID = workspaceID
    }

    private enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
    }
}

public struct MobileSimulatorStreamStartParameters: Codable, Equatable, Sendable {
    public let panelID: String
    public let workspaceID: String

    public init(panelID: String, workspaceID: String) {
        self.panelID = panelID
        self.workspaceID = workspaceID
    }

    private enum CodingKeys: String, CodingKey {
        case panelID = "panel_id"
        case workspaceID = "workspace_id"
    }
}

public struct MobileSimulatorPanelParameters: Codable, Equatable, Sendable {
    public let panelID: String
    public let workspaceID: String

    public init(panelID: String, workspaceID: String) {
        self.panelID = panelID
        self.workspaceID = workspaceID
    }

    private enum CodingKeys: String, CodingKey {
        case panelID = "panel_id"
        case workspaceID = "workspace_id"
    }
}

public enum MobileSimulatorPointerPhase: String, Codable, Equatable, Sendable {
    case began
    case moved
    case ended
    case tap
}

public struct MobileSimulatorPointerInput: Codable, Equatable, Sendable {
    public let panelID: String
    public let workspaceID: String
    public let phase: MobileSimulatorPointerPhase
    public let x: Double
    public let y: Double

    public init(
        panelID: String,
        workspaceID: String,
        phase: MobileSimulatorPointerPhase,
        x: Double,
        y: Double
    ) {
        self.panelID = panelID
        self.workspaceID = workspaceID
        self.phase = phase
        self.x = x
        self.y = y
    }

    private enum CodingKeys: String, CodingKey {
        case panelID = "panel_id"
        case workspaceID = "workspace_id"
        case phase
        case x
        case y
    }
}

public struct MobileSimulatorTextInput: Codable, Equatable, Sendable {
    public let panelID: String
    public let workspaceID: String
    public let text: String

    public init(panelID: String, workspaceID: String, text: String) {
        self.panelID = panelID
        self.workspaceID = workspaceID
        self.text = text
    }

    private enum CodingKeys: String, CodingKey {
        case panelID = "panel_id"
        case workspaceID = "workspace_id"
        case text
    }
}

public enum MobileSimulatorHardwareButton: String, Codable, CaseIterable, Equatable, Sendable {
    case home
    case swipeHome
    case appSwitcher
    case lock
    case siri
    case sideButton
    case power
    case volumeUp
    case volumeDown
    case action
    case watchSideButton
}

public struct MobileSimulatorButtonInput: Codable, Equatable, Sendable {
    public let panelID: String
    public let workspaceID: String
    public let button: MobileSimulatorHardwareButton

    public init(panelID: String, workspaceID: String, button: MobileSimulatorHardwareButton) {
        self.panelID = panelID
        self.workspaceID = workspaceID
        self.button = button
    }

    private enum CodingKeys: String, CodingKey {
        case panelID = "panel_id"
        case workspaceID = "workspace_id"
        case button
    }
}

public struct MobileSimulatorClosedEvent: Codable, Equatable, Sendable {
    public let panelID: String

    public init(panelID: String) {
        self.panelID = panelID
    }

    private enum CodingKeys: String, CodingKey {
        case panelID = "panel_id"
    }
}
