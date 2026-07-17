public import Foundation

/// The versioned control-plane contract between the AppKit host and the
/// faceless Ghostty render worker.
public enum TerminalRenderProtocol {
    /// Bump when either side can no longer decode the other side's messages.
    public static let currentVersion: UInt32 = 2
}

/// A bootstrap endpoint for the separate Mach channel that transfers frames.
public struct TerminalRenderFrameEndpoint: Codable, Equatable, Sendable {
    /// Random bootstrap service registered by the host process.
    public let serviceName: String

    /// A random 128-bit value checked on every frame message.
    public let authenticationToken: Data

    /// Creates an endpoint after validating its fixed-size authentication token.
    public init(serviceName: String, authenticationToken: Data) throws {
        guard !serviceName.isEmpty,
              authenticationToken.count == TerminalRenderFrameTransport.authenticationTokenLength else {
            throw TerminalRenderProtocolError.invalidFrameEndpoint
        }
        self.serviceName = serviceName
        self.authenticationToken = authenticationToken
    }
}

/// A complete, already-finalized Ghostty configuration serialized in Ghostty's
/// own config-file format by the host.
public struct TerminalRenderConfigurationSnapshot: Codable, Equatable, Sendable {
    /// Monotonic host revision used to reject stale configuration updates.
    public let revision: UInt64

    /// Effective Ghostty configuration text.
    public let contents: String

    /// Creates a configuration snapshot.
    public init(revision: UInt64, contents: String) {
        self.revision = revision
        self.contents = contents
    }
}

/// Everything the worker needs to create a visual-only Ghostty mirror.
public struct TerminalRenderSurfaceDescriptor: Codable, Equatable, Sendable {
    /// Stable cmux surface identity.
    public let id: UUID

    /// Monotonic native-surface lifetime identity.
    public let generation: UInt64

    /// Initial pixel width.
    public let width: UInt32

    /// Initial pixel height.
    public let height: UInt32

    /// Initial horizontal backing scale.
    public let scaleX: Double

    /// Initial vertical backing scale.
    public let scaleY: Double

    /// Surface-local runtime font size. Zero inherits the app configuration.
    public let fontSize: Float

    /// Ghostty's surface-context raw value.
    public let context: Int32

    /// Creates a render-mirror descriptor.
    public init(
        id: UUID,
        generation: UInt64,
        width: UInt32,
        height: UInt32,
        scaleX: Double,
        scaleY: Double,
        fontSize: Float,
        context: Int32
    ) {
        self.id = id
        self.generation = generation
        self.width = width
        self.height = height
        self.scaleX = scaleX
        self.scaleY = scaleY
        self.fontSize = fontSize
        self.context = context
    }
}

/// A visual state transition replayed against one worker-owned mirror surface.
public enum TerminalRenderSurfaceMutation: Codable, Equatable, Sendable {
    /// Ordered raw PTY bytes, captured before the host parser consumes them.
    case processOutput(sequence: UInt64, bytes: Data)

    /// Pixel geometry changed.
    case resize(width: UInt32, height: UInt32)

    /// Backing scale changed.
    case contentScale(x: Double, y: Double)

    /// First-responder focus changed.
    case focus(Bool)

    /// Portal visibility changed.
    case occlusion(Bool)

    /// Host light/dark scheme changed, using Ghostty's raw enum value.
    case colorScheme(Int32)

    /// Worker GPU resources should be realized or reclaimed.
    case rendererRealized(Bool)

    /// Request a damage-driven redraw through Ghostty's normal wakeup path.
    case refresh

    /// IME marked text changed.
    case preedit(text: String?, selectionStart: Int, selectionLength: Int)

    /// Pointer position changed, using Ghostty modifier bits.
    case mousePosition(x: Double, y: Double, modifiers: UInt32)

    /// Pointer button changed, using Ghostty's raw state/button values.
    case mouseButton(state: Int32, button: Int32, modifiers: UInt32)

    /// Scroll-wheel input changed.
    case mouseScroll(deltaX: Double, deltaY: Double, modifiers: UInt32)

    /// Discard the mirror's selection.
    case clearSelection

    /// Applies one Ghostty binding action that changes visual state, such as
    /// viewport scrolling, copy mode, or a surface-local font adjustment.
    case bindingAction(String)
}

/// Host-to-worker control messages. The hot frame path never uses this pipe.
public enum TerminalRenderWorkerCommand: Codable, Equatable, Sendable {
    /// Establishes protocol/config/frame transport before any surface exists.
    case initialize(
        protocolVersion: UInt32,
        workerGeneration: UInt64,
        frameEndpoint: TerminalRenderFrameEndpoint,
        configuration: TerminalRenderConfigurationSnapshot
    )

    /// Atomically replaces the app configuration used by all mirror surfaces.
    case replaceConfiguration(TerminalRenderConfigurationSnapshot)

    /// Creates or replaces one mirror generation.
    case createSurface(TerminalRenderSurfaceDescriptor)

    /// Applies a mutation only if the generation is still current.
    case mutateSurface(id: UUID, generation: UInt64, mutation: TerminalRenderSurfaceMutation)

    /// Replaces a crashed worker's mirror with an atomic host snapshot. The
    /// next live output byte begins at `nextOutputSequence`.
    case resynchronizeSurface(
        descriptor: TerminalRenderSurfaceDescriptor,
        nextOutputSequence: UInt64,
        screenTailVT: Data
    )

    /// Destroys one mirror generation.
    case destroySurface(id: UUID, generation: UInt64)

    /// Clean worker termination used by app shutdown and tests.
    case shutdown
}

/// Worker-to-host control messages.
public enum TerminalRenderWorkerEvent: Codable, Equatable, Sendable {
    /// Worker accepted the protocol and connected its frame sender.
    case initialized(protocolVersion: UInt32, workerGeneration: UInt64, processIdentifier: Int32)

    /// A surface generation is ready to consume ordered output.
    case surfaceCreated(id: UUID, generation: UInt64)

    /// Worker finished freeing a surface generation.
    case surfaceDestroyed(id: UUID, generation: UInt64)

    /// Highest contiguous output byte position applied by a mirror.
    case outputApplied(id: UUID, generation: UInt64, nextSequence: UInt64)

    /// Pixel geometry applied by a mirror. The host uses this acknowledgement
    /// to release the next ordered resize without accumulating stale sizes.
    case resizeApplied(id: UUID, generation: UInt64, width: UInt32, height: UInt32)

    /// Recoverable protocol/runtime diagnostic. User-facing UI is intentionally
    /// absent; supervision logs it and respawns when required.
    case failure(String)
}

/// Validation or encoding failures in the terminal render protocol.
public enum TerminalRenderProtocolError: Error, Equatable, Sendable {
    case invalidFrameEndpoint
    case encodingFailed
    case decodingFailed
}

/// Binary-property-list codec used only by the low-volume control pipe.
public enum TerminalRenderControlCodec {
    /// Encodes a host command without JSON/base64 expansion of PTY bytes.
    public static func encode(_ command: TerminalRenderWorkerCommand) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        do {
            return try encoder.encode(command)
        } catch {
            throw TerminalRenderProtocolError.encodingFailed
        }
    }

    /// Decodes a host command.
    public static func decodeCommand(_ data: Data) throws -> TerminalRenderWorkerCommand {
        do {
            return try PropertyListDecoder().decode(TerminalRenderWorkerCommand.self, from: data)
        } catch {
            throw TerminalRenderProtocolError.decodingFailed
        }
    }

    /// Encodes a worker event.
    public static func encode(_ event: TerminalRenderWorkerEvent) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        do {
            return try encoder.encode(event)
        } catch {
            throw TerminalRenderProtocolError.encodingFailed
        }
    }

    /// Decodes a worker event.
    public static func decodeEvent(_ data: Data) throws -> TerminalRenderWorkerEvent {
        do {
            return try PropertyListDecoder().decode(TerminalRenderWorkerEvent.self, from: data)
        } catch {
            throw TerminalRenderProtocolError.decodingFailed
        }
    }
}
