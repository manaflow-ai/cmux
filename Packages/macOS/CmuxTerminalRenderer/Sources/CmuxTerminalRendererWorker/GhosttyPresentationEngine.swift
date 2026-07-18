internal import CmuxTerminalRendererRuntime
internal import CmuxTerminalRenderProtocol
internal import CmuxTerminalRendererControl
internal import CmuxTerminalRenderTransport
internal import Foundation
internal import GhosttyKit
internal import IOSurface
internal import OSLog

nonisolated private let logger = Logger(
    subsystem: "com.cmuxterm.cmux-terminal-renderer",
    category: "ghostty-scene-renderer"
)

struct GhosttyPresentationEngineFactory: RendererPresentationEngineFactory {
    init() throws {
        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
            throw RendererPresentationEngineError.invariantViolation
        }
    }

    func makeEngine(
        context: RendererPresentationEngineContext
    ) throws -> any RendererPresentationEngine {
        try GhosttyPresentationEngine(context: context)
    }
}

private final class GhosttySceneCallbackContext {
    var pendingFrame: RendererFrameLease?
    var duplicateFrame = false
    var unhealthy = false

    func reset() {
        pendingFrame = nil
        duplicateFrame = false
        unhealthy = false
    }
}

private final class GhosttyPresentationEngine: RendererPresentationEngine, @unchecked Sendable {
    private let sender: TerminalRenderFrameSender
    private let callbackContext = GhosttySceneCallbackContext()
    private var renderer: ghostty_scene_renderer_t?
    private var closed = false

    init(context: RendererPresentationEngineContext) throws {
        let attachment = context.attachment
        guard attachment.pixelFormat == .bgra8Unorm,
              attachment.terminalEpoch != 0,
              !attachment.resolvedConfig.contains(0),
              String(data: attachment.resolvedConfig, encoding: .utf8) != nil else {
            throw RendererPresentationEngineError.invariantViolation
        }
        sender = try TerminalRenderFrameSender(endpoint: attachment.frameEndpoint)

        guard let config = ghostty_config_new() else {
            throw RendererPresentationEngineError.resourceExhausted
        }
        defer { ghostty_config_free(config) }
        if !attachment.resolvedConfig.isEmpty {
            let syntheticPath = "/__cmux_renderer__/resolved.conf"
            attachment.resolvedConfig.withUnsafeBytes { bytes in
                syntheticPath.withCString { path in
                    ghostty_config_load_string(
                        config,
                        bytes.bindMemory(to: CChar.self).baseAddress,
                        UInt(bytes.count),
                        path
                    )
                }
            }
        }
        ghostty_config_finalize(config)
        guard ghostty_config_diagnostics_count(config) == 0 else {
            throw RendererPresentationEngineError.invariantViolation
        }

        var options = ghostty_scene_renderer_options_s()
        options.config = config
        options.width = attachment.width
        options.height = attachment.height
        options.padding_mode = GHOSTTY_SCENE_RENDERER_PADDING_CONFIG
        options.content_scale = attachment.backingScaleFactor
        options.renderer_epoch = context.rendererEpoch
        options.terminal_id = attachment.terminalID.uuid
        options.terminal_epoch = attachment.terminalEpoch
        options.presentation_id = attachment.presentationID.uuid
        options.presentation_generation = attachment.presentationGeneration
        options.max_scene_bytes = RendererControlProtocol.maximumSemanticSceneLength
        options.max_allocation_bytes = RendererControlProtocol.maximumSemanticSceneLength * 2
        options.userdata = Unmanaged.passUnretained(callbackContext).toOpaque()
        options.event_callback = { userdata, event, framePointer in
            guard let userdata else { return }
            let context = Unmanaged<GhosttySceneCallbackContext>
                .fromOpaque(userdata)
                .takeUnretainedValue()
            if event == GHOSTTY_SCENE_RENDERER_UNHEALTHY {
                context.unhealthy = true
                return
            }
            guard event == GHOSTTY_SCENE_RENDERER_FRAME_READY,
                  let frame = framePointer?.pointee else { return }
            if context.pendingFrame != nil {
                context.duplicateFrame = true
                return
            }
            context.pendingFrame = RendererFrameLease(
                rendererEpoch: frame.renderer_epoch,
                terminalID: UUID(uuid: frame.terminal_id),
                terminalEpoch: frame.terminal_epoch,
                terminalSequence: frame.content_sequence,
                presentationID: UUID(uuid: frame.presentation_id),
                presentationGeneration: frame.presentation_generation,
                presentationSequence: frame.presentation_sequence,
                frameSequence: frame.frame_sequence,
                surfaceID: frame.iosurface_id,
                width: frame.width,
                height: frame.height
            )
        }

        var status = GHOSTTY_SCENE_RENDERER_SUCCESS
        guard let renderer = ghostty_scene_renderer_new(&options, &status) else {
            throw Self.error(for: status)
        }
        self.renderer = renderer
    }

    deinit {
        guard let renderer else { return }
        let status = ghostty_scene_renderer_destroy(renderer)
        if status != GHOSTTY_SCENE_RENDERER_SUCCESS {
            logger.fault("renderer deinit left status=\(status.rawValue, privacy: .public)")
        }
    }

    func apply(scene: RendererSemanticScene) throws {
        guard let renderer, !closed, !scene.bytes.isEmpty else {
            throw RendererPresentationEngineError.invalidScene
        }
        let status = scene.bytes.withUnsafeBytes { bytes in
            ghostty_scene_renderer_apply(
                renderer,
                bytes.bindMemory(to: UInt8.self).baseAddress,
                bytes.count
            )
        }
        guard status == GHOSTTY_SCENE_RENDERER_SUCCESS else {
            throw Self.error(for: status)
        }
    }

    func metrics() throws -> RendererPresentationGeometry {
        guard let renderer, !closed else {
            throw RendererPresentationEngineError.invariantViolation
        }
        var metrics = ghostty_scene_renderer_metrics_s()
        let status = ghostty_scene_renderer_get_metrics(renderer, &metrics)
        guard status == GHOSTTY_SCENE_RENDERER_SUCCESS else {
            throw Self.error(for: status)
        }
        return RendererPresentationGeometry(
            columns: metrics.columns,
            rows: metrics.rows,
            cellWidth: metrics.cell_width,
            cellHeight: metrics.cell_height,
            paddingTop: metrics.padding_top,
            paddingRight: metrics.padding_right,
            paddingBottom: metrics.padding_bottom,
            paddingLeft: metrics.padding_left
        )
    }

    func shouldAnimate(visible: Bool) throws -> Bool {
        guard let renderer, !closed else {
            throw RendererPresentationEngineError.invariantViolation
        }
        var result = false
        let status = ghostty_scene_renderer_should_animate(
            renderer,
            visible,
            &result
        )
        guard status == GHOSTTY_SCENE_RENDERER_SUCCESS else {
            throw Self.error(for: status)
        }
        return result
    }

    func render() throws -> RendererFrameLease {
        guard let renderer, !closed else {
            throw RendererPresentationEngineError.invariantViolation
        }
        callbackContext.reset()
        let status = ghostty_scene_renderer_render(renderer)
        guard status == GHOSTTY_SCENE_RENDERER_SUCCESS else {
            throw Self.error(for: status)
        }
        guard !callbackContext.unhealthy,
              !callbackContext.duplicateFrame,
              let frame = callbackContext.pendingFrame else {
            throw RendererPresentationEngineError.gpuFailure
        }
        callbackContext.pendingFrame = nil
        return frame
    }

    func publish(
        lease: RendererFrameLease,
        metadata: TerminalRenderFrameMetadata
    ) async throws -> RendererFramePublishDisposition {
        guard let renderer, !closed else {
            throw RendererPresentationEngineError.invariantViolation
        }
        var frame = Self.ghosttyFrame(from: lease)
        var rawSurface: UnsafeMutableRawPointer?
        let status = ghostty_scene_renderer_borrow_iosurface(
            renderer,
            &frame,
            &rawSurface
        )
        guard status == GHOSTTY_SCENE_RENDERER_SUCCESS,
              let rawSurface else {
            throw Self.error(for: status)
        }
        let surface = Unmanaged<IOSurfaceRef>
            .fromOpaque(rawSurface)
            .takeUnretainedValue()
        let handle = TerminalRenderSurfaceHandle(surface: surface)
        guard handle.identifier == lease.surfaceID,
              handle.width == Int(lease.width),
              handle.height == Int(lease.height),
              handle.pixelFormat == TerminalRenderPixelFormat.bgra8Unorm.rawValue else {
            throw RendererPresentationEngineError.invariantViolation
        }
        switch try await sender.send(surface: handle, metadata: metadata) {
        case .sent:
            return .sent
        case .droppedQueueFull:
            return .droppedQueueFull
        }
    }

    func release(lease: RendererFrameLease) throws {
        guard let renderer, !closed else {
            throw RendererPresentationEngineError.invariantViolation
        }
        var frame = Self.ghosttyFrame(from: lease)
        let status = ghostty_scene_renderer_release_frame(renderer, &frame)
        guard status == GHOSTTY_SCENE_RENDERER_SUCCESS else {
            throw Self.error(for: status)
        }
    }

    func close() async throws {
        guard !closed else { return }
        await sender.stop()
        guard let renderer else {
            closed = true
            return
        }
        let status = ghostty_scene_renderer_destroy(renderer)
        guard status == GHOSTTY_SCENE_RENDERER_SUCCESS else {
            throw Self.error(for: status)
        }
        self.renderer = nil
        closed = true
    }

    private static func ghosttyFrame(
        from lease: RendererFrameLease
    ) -> ghostty_scene_renderer_frame_s {
        var frame = ghostty_scene_renderer_frame_s()
        frame.renderer_epoch = lease.rendererEpoch
        frame.terminal_id = lease.terminalID.uuid
        frame.terminal_epoch = lease.terminalEpoch
        frame.content_sequence = lease.terminalSequence
        frame.presentation_id = lease.presentationID.uuid
        frame.presentation_generation = lease.presentationGeneration
        frame.presentation_sequence = lease.presentationSequence
        frame.frame_sequence = lease.frameSequence
        frame.iosurface_id = lease.surfaceID
        frame.width = lease.width
        frame.height = lease.height
        return frame
    }

    private static func error(
        for status: ghostty_scene_renderer_status_e
    ) -> RendererPresentationEngineError {
        switch status {
        case GHOSTTY_SCENE_RENDERER_BUSY:
            .busy
        case GHOSTTY_SCENE_RENDERER_INVALID_SCENE,
             GHOSTTY_SCENE_RENDERER_NO_SCENE:
            .invalidScene
        case GHOSTTY_SCENE_RENDERER_REPLAY_REJECTED:
            .replayRejected
        case GHOSTTY_SCENE_RENDERER_UNSUPPORTED_CAPABILITY,
             GHOSTTY_SCENE_RENDERER_UNSUPPORTED:
            .unsupportedSceneCapability
        case GHOSTTY_SCENE_RENDERER_OUT_OF_MEMORY,
             GHOSTTY_SCENE_RENDERER_LIMIT_EXCEEDED:
            .resourceExhausted
        case GHOSTTY_SCENE_RENDERER_GPU_ERROR:
            .gpuFailure
        default:
            .invariantViolation
        }
    }
}
