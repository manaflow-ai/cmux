internal import Darwin
public import Foundation
public import IOSurface
internal import Security
internal import TerminalRenderMachIPC

/// Metadata attached to one remotely rendered IOSurface.
public struct TerminalRenderFrameMetadata: Equatable, Sendable {
    /// Stable cmux surface identity.
    public let surfaceID: UUID

    /// Host-assigned worker lifetime identity.
    public let workerGeneration: UInt64

    /// Native mirror lifetime identity.
    public let surfaceGeneration: UInt64

    /// Monotonic frame identity within the generation.
    public let frameSequence: UInt64

    /// Pixel width of the IOSurface.
    public let width: UInt32

    /// Pixel height of the IOSurface.
    public let height: UInt32

    /// Creates frame metadata.
    public init(
        surfaceID: UUID,
        workerGeneration: UInt64,
        surfaceGeneration: UInt64,
        frameSequence: UInt64,
        width: UInt32,
        height: UInt32
    ) {
        self.surfaceID = surfaceID
        self.workerGeneration = workerGeneration
        self.surfaceGeneration = surfaceGeneration
        self.frameSequence = frameSequence
        self.width = width
        self.height = height
    }
}

/// A received IOSurface and its generation-fenced metadata.
///
/// IOSurface is a process-safe kernel object. The wrapper is unchecked
/// Sendable so the receive thread can hand ownership to the main actor, which
/// is the only place cmux assigns it to a presentation layer.
public final class TerminalRenderFrame: @unchecked Sendable {
    /// Frame identity and dimensions.
    public let metadata: TerminalRenderFrameMetadata

    /// Retained IOSurface imported from the worker's Mach capability.
    public let surface: IOSurfaceRef

    init(metadata: TerminalRenderFrameMetadata, surface: IOSurfaceRef) {
        self.metadata = metadata
        self.surface = surface
    }
}

/// Secure IOSurface frame transport between a render worker and its host.
public enum TerminalRenderFrameTransport {
    /// Authentication token length required by the C/Mach wire format.
    public static let authenticationTokenLength = Int(CMUX_TERMINAL_RENDER_TOKEN_LENGTH)

    /// Creates a cryptographically random token.
    public static func makeAuthenticationToken() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: authenticationTokenLength)
        let result = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard result == errSecSuccess else {
            throw TerminalRenderFrameTransportError.randomTokenFailed(result)
        }
        return Data(bytes)
    }
}

/// Host-owned receive endpoint for IOSurface frame capabilities.
public final class TerminalRenderFrameReceiver: @unchecked Sendable {
    /// Endpoint sent to the worker during control initialization.
    public let endpoint: TerminalRenderFrameEndpoint

    private let receivePort: mach_port_t
    private let stateLock = NSLock()
    private var stopped = false

    /// Registers a unique endpoint in the host's bootstrap namespace.
    public init(serviceName: String? = nil, authenticationToken: Data? = nil) throws {
        let resolvedName = serviceName
            ?? "dev.cmux.terminal-render.\(getpid()).\(UUID().uuidString)"
        let resolvedToken = try authenticationToken
            ?? TerminalRenderFrameTransport.makeAuthenticationToken()
        self.endpoint = try TerminalRenderFrameEndpoint(
            serviceName: resolvedName,
            authenticationToken: resolvedToken
        )

        var port = mach_port_t(MACH_PORT_NULL)
        let result = resolvedName.withCString {
            cmux_terminal_render_receiver_create($0, &port)
        }
        guard result == KERN_SUCCESS else {
            throw TerminalRenderFrameTransportError.receiverCreationFailed(result)
        }
        self.receivePort = port
    }

    deinit {
        stop()
    }

    /// Starts one blocking receive thread. Frames are delivered in Mach queue
    /// order; malformed messages are discarded without ending the endpoint.
    public func start(
        _ handler: @escaping @Sendable (TerminalRenderFrame) -> Void
    ) -> Thread {
        let thread = Thread { [weak self] in
            self?.receiveLoop(handler)
        }
        thread.name = "cmux-terminal-frame-receiver"
        thread.stackSize = 1 << 20
        thread.start()
        return thread
    }

    /// Destroys the receive right and wakes the receive thread.
    public func stop() {
        let shouldStop = stateLock.withLock {
            guard !stopped else { return false }
            stopped = true
            return true
        }
        if shouldStop {
            cmux_terminal_render_receiver_destroy(receivePort)
        }
    }

    private func receiveLoop(
        _ handler: @escaping @Sendable (TerminalRenderFrame) -> Void
    ) {
        while !stateLock.withLock({ stopped }) {
            do {
                if let frame = try receiveOne(timeoutMilliseconds: 250) {
                    handler(frame)
                }
            } catch TerminalRenderFrameTransportError.receiveTimedOut {
                continue
            } catch TerminalRenderFrameTransportError.invalidMessage {
                continue
            } catch {
                return
            }
        }
    }

    /// Receives one frame. Exposed for deterministic transport tests.
    public func receiveOne(timeoutMilliseconds: UInt32) throws -> TerminalRenderFrame? {
        var metadata = cmux_terminal_render_frame_metadata_s()
        var receivedSurface: Unmanaged<IOSurfaceRef>?
        let result: kern_return_t = endpoint.authenticationToken.withUnsafeBytes { token in
            guard let tokenAddress = token.bindMemory(to: UInt8.self).baseAddress else {
                return KERN_INVALID_ARGUMENT
            }
            return cmux_terminal_render_frame_receive(
                receivePort,
                timeoutMilliseconds,
                tokenAddress,
                &metadata,
                &receivedSurface
            )
        }
        if result == MACH_RCV_TIMED_OUT {
            throw TerminalRenderFrameTransportError.receiveTimedOut
        }
        if result == MIG_TYPE_ERROR {
            throw TerminalRenderFrameTransportError.invalidMessage
        }
        guard result == KERN_SUCCESS, let receivedSurface else {
            throw TerminalRenderFrameTransportError.receiveFailed(result)
        }
        let retainedSurface = receivedSurface.takeRetainedValue()

        let surfaceID = withUnsafeBytes(of: metadata.surface_id) { raw -> UUID in
            let bytes = raw.bindMemory(to: UInt8.self)
            return UUID(uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            ))
        }
        return TerminalRenderFrame(
            metadata: TerminalRenderFrameMetadata(
                surfaceID: surfaceID,
                workerGeneration: metadata.worker_generation,
                surfaceGeneration: metadata.surface_generation,
                frameSequence: metadata.frame_sequence,
                width: metadata.width,
                height: metadata.height
            ),
            surface: retainedSurface
        )
    }
}

/// Worker-owned sender endpoint. Sending never waits for host queue capacity.
public final class TerminalRenderFrameSender: @unchecked Sendable {
    private let sendPort: mach_port_t
    private let authenticationToken: Data

    /// Connects to a host endpoint inherited through the bootstrap namespace.
    public init(endpoint: TerminalRenderFrameEndpoint) throws {
        var port = mach_port_t(MACH_PORT_NULL)
        let result = endpoint.serviceName.withCString {
            cmux_terminal_render_sender_connect($0, &port)
        }
        guard result == KERN_SUCCESS else {
            throw TerminalRenderFrameTransportError.senderConnectionFailed(result)
        }
        self.sendPort = port
        self.authenticationToken = endpoint.authenticationToken
    }

    deinit {
        cmux_terminal_render_sender_destroy(sendPort)
    }

    /// Transfers one IOSurface. Returns false when the host queue is full so
    /// the renderer can discard an obsolete frame without blocking.
    @discardableResult
    public func send(
        surface: IOSurfaceRef,
        metadata swiftMetadata: TerminalRenderFrameMetadata
    ) throws -> Bool {
        var metadata = cmux_terminal_render_frame_metadata_s()
        _ = authenticationToken.copyBytes(
            to: withUnsafeMutableBytes(of: &metadata.authentication_token) {
                $0.bindMemory(to: UInt8.self)
            }
        )
        var uuid = swiftMetadata.surfaceID.uuid
        withUnsafeBytes(of: &uuid) { source in
            withUnsafeMutableBytes(of: &metadata.surface_id) { destination in
                destination.copyBytes(from: source)
            }
        }
        metadata.worker_generation = swiftMetadata.workerGeneration
        metadata.surface_generation = swiftMetadata.surfaceGeneration
        metadata.frame_sequence = swiftMetadata.frameSequence
        metadata.width = swiftMetadata.width
        metadata.height = swiftMetadata.height

        let result = cmux_terminal_render_frame_send(sendPort, surface, &metadata)
        if result == MACH_SEND_TIMED_OUT {
            return false
        }
        guard result == KERN_SUCCESS else {
            throw TerminalRenderFrameTransportError.sendFailed(result)
        }
        return true
    }
}

/// Mach/IOSurface transport failures.
public enum TerminalRenderFrameTransportError: Error, Equatable, Sendable {
    case randomTokenFailed(Int32)
    case receiverCreationFailed(kern_return_t)
    case senderConnectionFailed(kern_return_t)
    case sendFailed(kern_return_t)
    case receiveFailed(kern_return_t)
    case receiveTimedOut
    case invalidMessage
}
