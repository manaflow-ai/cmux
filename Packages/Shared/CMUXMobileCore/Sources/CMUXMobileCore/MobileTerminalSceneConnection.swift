public import Foundation

/// Transport-neutral request for one renderer-only terminal presentation.
public struct MobileTerminalSceneRequest: Equatable, Sendable {
    public let surfaceID: String
    public let presentationID: UUID
    public let presentationGeneration: UInt64
    public let width: UInt32
    public let height: UInt32
    public let contentScale: Double

    public init(
        surfaceID: String,
        presentationID: UUID,
        presentationGeneration: UInt64,
        width: UInt32,
        height: UInt32,
        contentScale: Double
    ) {
        self.surfaceID = surfaceID
        self.presentationID = presentationID
        self.presentationGeneration = presentationGeneration
        self.width = width
        self.height = height
        self.contentScale = contentScale
    }
}

/// Exact Ghostty configuration and identity fences for one scene renderer.
public struct MobileTerminalSceneConfiguration: Equatable, Sendable {
    public let terminalID: UUID
    public let terminalEpoch: UInt64
    public let presentationID: UUID
    public let presentationGeneration: UInt64
    public let rendererConfigRevision: UInt64
    public let width: UInt32
    public let height: UInt32
    public let contentScale: Double
    public let rendererConfig: Data

    public init(
        terminalID: UUID,
        terminalEpoch: UInt64,
        presentationID: UUID,
        presentationGeneration: UInt64,
        rendererConfigRevision: UInt64,
        width: UInt32,
        height: UInt32,
        contentScale: Double,
        rendererConfig: Data
    ) {
        self.terminalID = terminalID
        self.terminalEpoch = terminalEpoch
        self.presentationID = presentationID
        self.presentationGeneration = presentationGeneration
        self.rendererConfigRevision = rendererConfigRevision
        self.width = width
        self.height = height
        self.contentScale = contentScale
        self.rendererConfig = rendererConfig
    }
}

/// One full, delta, or presentation-only Ghostty semantic scene.
public struct MobileTerminalSceneFrame: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case full
        case delta
        case unchanged
    }

    public let terminalID: UUID
    public let terminalEpoch: UInt64
    public let contentSequence: UInt64
    public let presentationID: UUID
    public let presentationGeneration: UInt64
    public let presentationSequence: UInt64
    public let kind: Kind
    public let payload: Data

    public init(
        terminalID: UUID,
        terminalEpoch: UInt64,
        contentSequence: UInt64,
        presentationID: UUID,
        presentationGeneration: UInt64,
        presentationSequence: UInt64,
        kind: Kind,
        payload: Data
    ) {
        self.terminalID = terminalID
        self.terminalEpoch = terminalEpoch
        self.contentSequence = contentSequence
        self.presentationID = presentationID
        self.presentationGeneration = presentationGeneration
        self.presentationSequence = presentationSequence
        self.kind = kind
        self.payload = payload
    }
}

/// Canonical viewport text fenced to one presented semantic scene.
public struct MobileTerminalSceneAccessibility: Equatable, Sendable {
    public let terminalID: UUID
    public let terminalEpoch: UInt64
    public let contentSequence: UInt64
    public let presentationID: UUID
    public let presentationGeneration: UInt64
    public let presentationSequence: UInt64
    public let columns: Int
    public let rows: Int
    public let text: String

    public init(
        terminalID: UUID,
        terminalEpoch: UInt64,
        contentSequence: UInt64,
        presentationID: UUID,
        presentationGeneration: UInt64,
        presentationSequence: UInt64,
        columns: Int,
        rows: Int,
        text: String
    ) {
        self.terminalID = terminalID
        self.terminalEpoch = terminalEpoch
        self.contentSequence = contentSequence
        self.presentationID = presentationID
        self.presentationGeneration = presentationGeneration
        self.presentationSequence = presentationSequence
        self.columns = columns
        self.rows = rows
        self.text = text
    }
}

/// One validated record on a terminal semantic-scene lane.
public enum MobileTerminalSceneEnvelope: Equatable, Sendable {
    case configuration(MobileTerminalSceneConfiguration)
    case scene(MobileTerminalSceneFrame)
    case accessibility(MobileTerminalSceneAccessibility)
}

public enum MobileTerminalSceneTermination: Equatable, Sendable {
    case ended
    case failed
}

/// One independently cancellable semantic-scene presentation.
public protocol MobileTerminalSceneConnection: Sendable {
    func receiveEnvelope() async throws -> MobileTerminalSceneEnvelope?
    func sendInput(_ input: Data) async throws
    func close() async
}

/// Opens a semantic-scene lane on the already-admitted peer connection.
public typealias MobileTerminalSceneProvider = @Sendable (
    _ request: CmxByteTransportRequest,
    _ scene: MobileTerminalSceneRequest
) async throws -> any MobileTerminalSceneConnection
