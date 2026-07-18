public import CmuxTerminalRenderProtocol
public import CmuxTerminalRendererControl
public import Foundation

/// Result of a nonblocking publish into the host's bounded Mach queue.
public enum RendererFramePublishDisposition: Equatable, Sendable {
    case sent
    case droppedQueueFull
}

/// Exact physical-pixel grid geometry owned by one standalone renderer.
public struct RendererPresentationGeometry: Equatable, Sendable {
    public let columns: UInt32
    public let rows: UInt32
    public let cellWidth: UInt32
    public let cellHeight: UInt32
    public let paddingTop: UInt32
    public let paddingRight: UInt32
    public let paddingBottom: UInt32
    public let paddingLeft: UInt32

    public init(
        columns: UInt32,
        rows: UInt32,
        cellWidth: UInt32,
        cellHeight: UInt32,
        paddingTop: UInt32,
        paddingRight: UInt32,
        paddingBottom: UInt32,
        paddingLeft: UInt32
    ) {
        self.columns = columns
        self.rows = rows
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.paddingTop = paddingTop
        self.paddingRight = paddingRight
        self.paddingBottom = paddingBottom
        self.paddingLeft = paddingLeft
    }
}

/// Failures classified at the standalone Ghostty renderer boundary.
public enum RendererPresentationEngineError: Error, Equatable, Sendable {
    case busy
    case invalidScene
    case replayRejected
    case unsupportedSceneCapability
    case resourceExhausted
    case gpuFailure
    case frameTransportFailure
    case invariantViolation
}

/// Single-presentation renderer used only from the worker runtime actor.
///
/// Implementations may use `@unchecked Sendable` when all entry points are
/// serialized by ``RendererWorkerRuntime`` and their async publish delegates
/// mutable transport state to a separate actor.
public protocol RendererPresentationEngine: AnyObject, Sendable {
    func apply(scene: RendererSemanticScene) throws
    func metrics() throws -> RendererPresentationGeometry
    /// Returns whether resolved renderer policy wants another frame while the
    /// presentation remains attached and visible in this worker.
    func shouldAnimate(visible: Bool) throws -> Bool
    func render() throws -> RendererFrameLease
    func publish(
        lease: RendererFrameLease,
        metadata: TerminalRenderFrameMetadata
    ) async throws -> RendererFramePublishDisposition
    func release(lease: RendererFrameLease) throws
    func close() async throws
}

public extension RendererPresentationEngine {
    func shouldAnimate(visible _: Bool) throws -> Bool { false }
}

/// Immutable resources required to create one standalone presentation engine.
public struct RendererPresentationEngineContext: Sendable {
    public let daemonInstanceID: UUID
    public let rendererEpoch: UInt64
    public let attachment: RendererPresentationAttachment

    public init(
        daemonInstanceID: UUID,
        rendererEpoch: UInt64,
        attachment: RendererPresentationAttachment
    ) {
        self.daemonInstanceID = daemonInstanceID
        self.rendererEpoch = rendererEpoch
        self.attachment = attachment
    }
}

/// Constructs presentation engines after a validated attachment arrives.
public protocol RendererPresentationEngineFactory: Sendable {
    func makeEngine(
        context: RendererPresentationEngineContext
    ) throws -> any RendererPresentationEngine
}
