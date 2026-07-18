public import CmuxTerminalRenderProtocol
internal import Foundation
internal import TerminalRenderMachIPC

/// Renderer-owned, serialized sender for the bounded IOSurface frame queue.
public actor TerminalRenderFrameSender {
    /// Endpoint this sender resolved at creation.
    public nonisolated let endpoint: TerminalRenderFrameEndpoint

    private var sendPort: UInt32
    private let codec = TerminalRenderFrameMetadataCodec()
    private var stopped = false

    /// Resolves a host frame endpoint and retains its Mach send right.
    ///
    /// - Parameter endpoint: The capability-bearing endpoint supplied by the host.
    /// - Throws: ``TerminalRenderFrameTransportError/senderConnectionFailed(_:)`` on lookup failure.
    public init(endpoint: TerminalRenderFrameEndpoint) throws {
        guard Int(CMUX_TERMINAL_RENDER_CAPABILITY_LENGTH)
                == TerminalRenderFrameProtocol.capabilityLength,
              Int(CMUX_TERMINAL_RENDER_METADATA_LENGTH)
                == TerminalRenderFrameProtocol.metadataLength else {
            throw TerminalRenderFrameTransportError.bridgeContractMismatch
        }
        var port = mach_port_t(MACH_PORT_NULL)
        var machError: kern_return_t = KERN_SUCCESS
        let status = endpoint.serviceName.withCString {
            cmux_terminal_render_sender_connect($0, &port, &machError)
        }
        guard status == CMUX_TERMINAL_RENDER_STATUS_SUCCESS else {
            throw TerminalRenderFrameTransportError.senderConnectionFailed(machError)
        }
        self.endpoint = endpoint
        self.sendPort = port
    }

    deinit {
        if sendPort != UInt32(MACH_PORT_NULL) {
            cmux_terminal_render_sender_destroy(sendPort)
        }
    }

    /// Transfers an IOSurface send right without waiting for host queue capacity.
    ///
    /// - Parameters:
    ///   - surface: Renderer-owned IOSurface wrapper.
    ///   - metadata: Complete frame provenance and presentation fences.
    /// - Returns: Whether the message was queued or dropped because the queue was full.
    /// - Throws: ``TerminalRenderFrameTransportError`` after teardown or a Mach send failure.
    public func send(
        surface: TerminalRenderSurfaceHandle,
        metadata: TerminalRenderFrameMetadata
    ) throws -> TerminalRenderFrameDelivery {
        guard !stopped else {
            throw TerminalRenderFrameTransportError.stopped
        }
        let encodedMetadata = codec.encode(metadata)
        var machError: kern_return_t = KERN_SUCCESS
        let status = endpoint.capability.withUnsafeBytes { capabilityBytes in
            encodedMetadata.withUnsafeBytes { metadataBytes in
                cmux_terminal_render_frame_send(
                    sendPort,
                    surface.surface,
                    capabilityBytes.bindMemory(to: UInt8.self).baseAddress!,
                    metadataBytes.bindMemory(to: UInt8.self).baseAddress!,
                    &machError
                )
            }
        }
        switch status {
        case CMUX_TERMINAL_RENDER_STATUS_SUCCESS:
            return .sent
        case CMUX_TERMINAL_RENDER_STATUS_QUEUE_FULL:
            return .droppedQueueFull
        default:
            throw TerminalRenderFrameTransportError.sendFailed(machError)
        }
    }

    /// Releases the Mach send right. Further sends fail with `stopped`.
    public func stop() {
        guard !stopped else { return }
        stopped = true
        if sendPort != UInt32(MACH_PORT_NULL) {
            cmux_terminal_render_sender_destroy(sendPort)
            sendPort = UInt32(MACH_PORT_NULL)
        }
    }
}
