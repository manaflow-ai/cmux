import Foundation

public enum CMUXSimulatorState: String, Codable, Hashable, Sendable {
    case creating
    case shutdown
    case booting
    case booted
    case shuttingDown
    case unknown

    public var isBooted: Bool { self == .booted }

    public var displayName: String {
        switch self {
        case .creating: return "Creating"
        case .shutdown: return "Shutdown"
        case .booting: return "Booting"
        case .booted: return "Booted"
        case .shuttingDown: return "Shutting Down"
        case .unknown: return "Unknown"
        }
    }
}

public struct CMUXSimulatorSize: Codable, Hashable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public static let zero = CMUXSimulatorSize(width: 0, height: 0)
}

public struct CMUXSimulatorDevice: Identifiable, Codable, Hashable, Sendable {
    public var id: String { udid }
    public let udid: String
    public let name: String
    public let state: CMUXSimulatorState
    public let runtime: String
    public let screenSizePoints: CMUXSimulatorSize
    public let screenSizePixels: CMUXSimulatorSize

    public init(
        udid: String,
        name: String,
        state: CMUXSimulatorState,
        runtime: String,
        screenSizePoints: CMUXSimulatorSize = .zero,
        screenSizePixels: CMUXSimulatorSize = .zero
    ) {
        self.udid = udid
        self.name = name
        self.state = state
        self.runtime = runtime
        self.screenSizePoints = screenSizePoints
        self.screenSizePixels = screenSizePixels
    }

    public var isBooted: Bool { state.isBooted }

    public var shortUDID: String {
        String(udid.prefix(8))
    }
}

public enum CMUXSimulatorTouchPhase: Sendable {
    case down
    case move
    case up
    case hover
}

public struct CMUXSimulatorPoint: Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public enum CMUXSimulatorHardwareAction: String, CaseIterable, Sendable {
    case home
    case lock
    case volumeUp
    case volumeDown
    case screenshot
    case rotateLeft
    case rotateRight
    case shake

    public var displayName: String {
        switch self {
        case .home: return "Home"
        case .lock: return "Lock"
        case .volumeUp: return "Volume Up"
        case .volumeDown: return "Volume Down"
        case .screenshot: return "Screenshot"
        case .rotateLeft: return "Rotate Left"
        case .rotateRight: return "Rotate Right"
        case .shake: return "Shake"
        }
    }
}

public struct CMUXSimulatorCapabilityReport: Sendable {
    public let xcodeMajorVersion: Int?
    public let minimumXcodeMajorVersion: Int
    public let developerDirectory: String
    public let failures: [String]

    public init(
        xcodeMajorVersion: Int?,
        minimumXcodeMajorVersion: Int,
        developerDirectory: String,
        failures: [String]
    ) {
        self.xcodeMajorVersion = xcodeMajorVersion
        self.minimumXcodeMajorVersion = minimumXcodeMajorVersion
        self.developerDirectory = developerDirectory
        self.failures = failures
    }

    public var isUsable: Bool {
        failures.isEmpty
    }

    public var failureSummary: String? {
        failures.first
    }
}

public enum CMUXSimulatorError: Error, LocalizedError, Equatable {
    case capabilityUnavailable(String)
    case deviceNotFound(String)
    case bootFailed(String)
    case shutdownFailed(String)
    case screenUnavailable(String)
    case inputUnavailable(String)
    case actionUnsupported(String)
    case processFailed(String)

    public var errorDescription: String? {
        switch self {
        case .capabilityUnavailable(let message),
             .bootFailed(let message),
             .shutdownFailed(let message),
             .screenUnavailable(let message),
             .inputUnavailable(let message),
             .actionUnsupported(let message),
             .processFailed(let message):
            return message
        case .deviceNotFound(let udid):
            return "Simulator not found: \(udid)"
        }
    }
}

public struct CMUXSimulatorFrameMetrics: Equatable, Sendable {
    public let pixelSize: CMUXSimulatorSize
    public let fps: Double

    public init(pixelSize: CMUXSimulatorSize, fps: Double) {
        self.pixelSize = pixelSize
        self.fps = fps
    }
}
