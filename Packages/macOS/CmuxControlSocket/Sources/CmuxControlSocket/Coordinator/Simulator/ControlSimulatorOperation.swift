public import Foundation

public struct ControlSimulatorTouch: Sendable, Equatable {
    public let phase: String
    public let x: Double
    public let y: Double
    public let secondX: Double?
    public let secondY: Double?
    public let edge: String

    public init(
        phase: String,
        x: Double,
        y: Double,
        secondX: Double? = nil,
        secondY: Double? = nil,
        edge: String = "none"
    ) {
        self.phase = phase
        self.x = x
        self.y = y
        self.secondX = secondX
        self.secondY = secondY
        self.edge = edge
    }
}

public enum ControlSimulatorOperation: Sendable, Equatable {
    case gesture([ControlSimulatorTouch])
    case hardwareButton(String)
    case rotate(String)
    case coreAnimation(diagnostic: String, enabled: Bool)
    case memoryWarning
    case eventLog(limit: Int)
    case cameraConfigure(
        source: String,
        path: String?,
        loops: Bool,
        hostDeviceID: String?,
        bundleIdentifier: String?
    )
    case cameraSwitch(source: String, path: String?, loops: Bool, hostDeviceID: String?)
    case cameraMirror(String)
    case cameraStatus
    /// Read the selected app's effective permission values.
    case permissionsRead(bundleIdentifier: String?)
    /// Grant, revoke, or reset one canonical permission service.
    case permissionsSet(action: String, service: String, bundleIdentifier: String)
    /// Read every supported Simulator-wide interface setting.
    case interfaceStatus
    /// Set one canonical Simulator-wide interface option.
    case interfaceSet(option: String, value: String)
    /// Read a bounded accessibility tree from the isolated worker.
    case accessibility
    /// Read metadata for the frontmost simulated application.
    case foregroundApplication
}

public enum ControlSimulatorOperationCompletion: Sendable, Equatable {
    case success(JSONValue)
    case failed(code: String, message: String)
}

public final class ControlSimulatorOperationReceipt: @unchecked Sendable {
    private let condition = NSCondition()
    private var completion: ControlSimulatorOperationCompletion?

    public init() {}

    public func complete(_ completion: ControlSimulatorOperationCompletion) {
        condition.lock()
        defer { condition.unlock() }
        guard self.completion == nil else { return }
        self.completion = completion
        condition.broadcast()
    }

    public func wait(timeout: TimeInterval) -> ControlSimulatorOperationCompletion? {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while completion == nil {
            guard condition.wait(until: deadline) else { break }
        }
        return completion
    }
}

public enum ControlSimulatorOperationStartResolution: Sendable {
    case started(surfaceID: UUID, timeoutSeconds: TimeInterval, receipt: ControlSimulatorOperationReceipt)
    case failed(ControlSimulatorTargetFailure)
    case unavailable(String)
    case invalid(String)
}
