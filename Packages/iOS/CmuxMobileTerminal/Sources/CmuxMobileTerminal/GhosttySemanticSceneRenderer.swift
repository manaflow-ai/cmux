#if canImport(UIKit)
import CMUXMobileCore
import Foundation
import GhosttyKit
import IOSurface
@preconcurrency import Metal
import QuartzCore

public enum GhosttySemanticSceneRendererError: Error, Equatable, Sendable {
    case invalidConfiguration
    case invalidScene
    case rendererUnavailable
    case rendererBusy
    case rendererRejectedScene
    case unsupportedScene
    case resourceExhausted
    case gpuFailure
    case identityMismatch
    case unexpectedConfiguration
    case missingConfiguration
}

/// Pixel and cell geometry produced by the renderer that owns the visible frame.
public struct GhosttySemanticSceneMetrics: Equatable, Sendable {
    public let columns: Int
    public let rows: Int
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let cellWidth: Int
    public let cellHeight: Int
    public let paddingTop: Int
    public let paddingRight: Int
    public let paddingBottom: Int
    public let paddingLeft: Int
}

/// One settled drawable allocation requested by the semantic surface host.
public struct GhosttySemanticSceneGeometry: Equatable, Sendable {
    public let width: UInt32
    public let height: UInt32
    public let contentScale: Double

    public init(width: UInt32, height: UInt32, contentScale: Double) {
        self.width = width
        self.height = height
        self.contentScale = contentScale
    }
}

/// A single-threaded renderer-only Ghostty scene consumer and Metal presenter.
///
/// It owns no Ghostty Surface, terminal parser, PTY, mailbox, or terminal IO
/// thread. The serial queue applies a scene, renders it, copies the leased
/// IOSurface into one CAMetalLayer drawable, waits off-main for GPU completion,
/// then returns the exact frame lease before reading the next scene.
public final class GhosttySemanticSceneRenderer: @unchecked Sendable {
    private final class CallbackContext {
        var frame: ghostty_scene_renderer_frame_s?
        var duplicateFrame = false
        var unhealthy = false

        func reset() {
            frame = nil
            duplicateFrame = false
            unhealthy = false
        }
    }

    private struct Core {
        var renderer: ghostty_scene_renderer_t
        let configuration: MobileTerminalSceneConfiguration
        var lastContentSequence: UInt64 = 0
        var lastPresentationSequence: UInt64 = 0
        var lastFrameSequence: UInt64 = 0
        var hasPresentedFrame = false
    }

    private let queue = DispatchQueue(
        label: "ai.manaflow.cmux.ios.semantic-scene-renderer",
        qos: .userInteractive
    )
    private let callbackContext = CallbackContext()
    private let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue
    private let presentationLayer: CAMetalLayer
    private let fontSizeOverride: Float32?
    private var core: Core?
    private var closed = false

    public init(
        presentationLayer: CAMetalLayer,
        fontSizeOverride: Float32? = nil
    ) throws {
        guard let device = presentationLayer.device ?? MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw GhosttySemanticSceneRendererError.rendererUnavailable
        }
        if let fontSizeOverride {
            guard fontSizeOverride.isFinite,
                  fontSizeOverride >= MobileTerminalFontPreference.minimumSize,
                  fontSizeOverride <= MobileTerminalFontPreference.maximumSize else {
                throw GhosttySemanticSceneRendererError.invalidConfiguration
            }
        }
        if presentationLayer.device == nil {
            presentationLayer.device = device
        }
        self.device = device
        self.commandQueue = commandQueue
        self.presentationLayer = presentationLayer
        self.fontSizeOverride = fontSizeOverride
    }

    deinit {
        guard let renderer = core?.renderer else { return }
        _ = ghostty_scene_renderer_destroy(renderer)
    }

    /// Applies one configuration or scene and presents scenes before returning.
    public func consume(
        _ envelope: MobileTerminalSceneEnvelope
    ) async throws -> GhosttySemanticSceneMetrics? {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    let result = try consumeOnQueue(envelope)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Renders the current scene again for shader or cursor animation.
    public func renderAnimationFrame() async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    guard var core, !closed else {
                        throw GhosttySemanticSceneRendererError.missingConfiguration
                    }
                    guard core.hasPresentedFrame,
                          core.lastContentSequence > 0,
                          core.lastPresentationSequence > 0 else {
                        throw GhosttySemanticSceneRendererError.invalidScene
                    }
                    try renderAndPresent(
                        core: &core,
                        expectedContentSequence: core.lastContentSequence,
                        expectedPresentationSequence: core.lastPresentationSequence
                    )
                    self.core = core
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func shouldAnimate(visible: Bool) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    guard let core, !closed else {
                        throw GhosttySemanticSceneRendererError.missingConfiguration
                    }
                    var result = false
                    let status = ghostty_scene_renderer_should_animate(
                        core.renderer,
                        visible,
                        &result
                    )
                    guard status == GHOSTTY_SCENE_RENDERER_SUCCESS else {
                        throw Self.error(for: status)
                    }
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func close() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard !closed else {
                    continuation.resume()
                    return
                }
                closed = true
                if let renderer = core?.renderer {
                    _ = ghostty_scene_renderer_destroy(renderer)
                }
                core = nil
                continuation.resume()
            }
        }
    }

    private func consumeOnQueue(
        _ envelope: MobileTerminalSceneEnvelope
    ) throws -> GhosttySemanticSceneMetrics? {
        guard !closed else {
            throw GhosttySemanticSceneRendererError.rendererUnavailable
        }
        switch envelope {
        case let .configuration(configuration):
            guard core == nil else {
                throw GhosttySemanticSceneRendererError.unexpectedConfiguration
            }
            let created = try makeCore(configuration: configuration)
            core = created
            return try metrics(core: created)
        case let .scene(scene):
            guard var core else {
                throw GhosttySemanticSceneRendererError.missingConfiguration
            }
            try validate(scene: scene, for: core)
            let status = scene.payload.withUnsafeBytes { bytes in
                ghostty_scene_renderer_apply(
                    core.renderer,
                    bytes.bindMemory(to: UInt8.self).baseAddress,
                    bytes.count
                )
            }
            guard status == GHOSTTY_SCENE_RENDERER_SUCCESS else {
                throw Self.error(for: status)
            }
            core.lastContentSequence = scene.contentSequence
            core.lastPresentationSequence = scene.presentationSequence
            self.core = core
            return nil
        case let .accessibility(accessibility):
            guard var core else {
                throw GhosttySemanticSceneRendererError.missingConfiguration
            }
            let configuration = core.configuration
            guard accessibility.terminalID == configuration.terminalID,
                  accessibility.terminalEpoch == configuration.terminalEpoch,
                  accessibility.presentationID == configuration.presentationID,
                  accessibility.presentationGeneration
                    == configuration.presentationGeneration,
                  accessibility.contentSequence == core.lastContentSequence,
                  accessibility.presentationSequence
                    == core.lastPresentationSequence else {
                throw GhosttySemanticSceneRendererError.identityMismatch
            }
            let rendererMetrics = try metrics(core: core)
            guard accessibility.columns == rendererMetrics.columns,
                  accessibility.rows == rendererMetrics.rows else {
                return nil
            }
            try renderAndPresent(
                core: &core,
                expectedContentSequence: accessibility.contentSequence,
                expectedPresentationSequence: accessibility.presentationSequence
            )
            core.hasPresentedFrame = true
            self.core = core
            return rendererMetrics
        }
    }

    private func makeCore(
        configuration: MobileTerminalSceneConfiguration
    ) throws -> Core {
        guard !configuration.rendererConfig.isEmpty,
              configuration.width > 0,
              configuration.height > 0,
              configuration.contentScale.isFinite,
              configuration.contentScale > 0,
              let config = ghostty_config_new() else {
            throw GhosttySemanticSceneRendererError.invalidConfiguration
        }
        defer { ghostty_config_free(config) }
        let syntheticPath = "/__cmux_ios_scene__/resolved.conf"
        var resolvedConfiguration = configuration.rendererConfig
        if let fontSizeOverride {
            resolvedConfiguration.append(
                Data("\nfont-size = \(fontSizeOverride)\n".utf8)
            )
        }
        resolvedConfiguration.withUnsafeBytes { bytes in
            syntheticPath.withCString { path in
                ghostty_config_load_string(
                    config,
                    bytes.bindMemory(to: CChar.self).baseAddress,
                    UInt(bytes.count),
                    path
                )
            }
        }
        ghostty_config_finalize(config)
        guard ghostty_config_diagnostics_count(config) == 0 else {
            throw GhosttySemanticSceneRendererError.invalidConfiguration
        }

        var options = ghostty_scene_renderer_options_s()
        options.config = config
        options.width = configuration.width
        options.height = configuration.height
        options.padding_mode = GHOSTTY_SCENE_RENDERER_PADDING_CONFIG
        options.content_scale = configuration.contentScale
        options.renderer_epoch = configuration.presentationGeneration
        options.terminal_id = configuration.terminalID.uuid
        options.terminal_epoch = configuration.terminalEpoch
        options.presentation_id = configuration.presentationID.uuid
        options.presentation_generation = configuration.presentationGeneration
        options.max_scene_bytes = 64 * 1_024 * 1_024
        options.max_allocation_bytes = 128 * 1_024 * 1_024
        options.userdata = Unmanaged.passUnretained(callbackContext).toOpaque()
        options.event_callback = { userdata, event, framePointer in
            guard let userdata else { return }
            let context = Unmanaged<CallbackContext>
                .fromOpaque(userdata)
                .takeUnretainedValue()
            if event == GHOSTTY_SCENE_RENDERER_UNHEALTHY {
                context.unhealthy = true
                return
            }
            guard event == GHOSTTY_SCENE_RENDERER_FRAME_READY,
                  let frame = framePointer?.pointee else { return }
            guard context.frame == nil else {
                context.duplicateFrame = true
                return
            }
            context.frame = frame
        }

        var status = GHOSTTY_SCENE_RENDERER_SUCCESS
        guard let renderer = ghostty_scene_renderer_new(&options, &status) else {
            throw Self.error(for: status)
        }
        return Core(renderer: renderer, configuration: configuration)
    }

    private func validate(
        scene: MobileTerminalSceneFrame,
        for core: Core
    ) throws {
        let configuration = core.configuration
        guard scene.terminalID == configuration.terminalID,
              scene.terminalEpoch == configuration.terminalEpoch,
              scene.presentationID == configuration.presentationID,
              scene.presentationGeneration == configuration.presentationGeneration,
              scene.presentationSequence == core.lastPresentationSequence + 1 else {
            throw GhosttySemanticSceneRendererError.identityMismatch
        }
    }

    private func renderAndPresent(
        core: inout Core,
        expectedContentSequence: UInt64,
        expectedPresentationSequence: UInt64
    ) throws {
        callbackContext.reset()
        let status = ghostty_scene_renderer_render(core.renderer)
        guard status == GHOSTTY_SCENE_RENDERER_SUCCESS else {
            throw Self.error(for: status)
        }
        guard !callbackContext.unhealthy,
              !callbackContext.duplicateFrame,
              var frame = callbackContext.frame else {
            throw GhosttySemanticSceneRendererError.gpuFailure
        }
        callbackContext.frame = nil

        let configuration = core.configuration
        guard frame.renderer_epoch == configuration.presentationGeneration,
              UUID(uuid: frame.terminal_id) == configuration.terminalID,
              frame.terminal_epoch == configuration.terminalEpoch,
              frame.content_sequence == expectedContentSequence,
              UUID(uuid: frame.presentation_id) == configuration.presentationID,
              frame.presentation_generation == configuration.presentationGeneration,
              frame.presentation_sequence == expectedPresentationSequence,
              frame.frame_sequence > core.lastFrameSequence else {
            _ = ghostty_scene_renderer_release_frame(core.renderer, &frame)
            throw GhosttySemanticSceneRendererError.identityMismatch
        }

        var retainedSurface: UnsafeMutableRawPointer?
        let retainStatus = ghostty_scene_renderer_retain_iosurface(
            core.renderer,
            &frame,
            &retainedSurface
        )
        guard retainStatus == GHOSTTY_SCENE_RENDERER_SUCCESS,
              let retainedSurface else {
            _ = ghostty_scene_renderer_release_frame(core.renderer, &frame)
            throw Self.error(for: retainStatus)
        }
        defer {
            ghostty_scene_renderer_release_retained_iosurface(retainedSurface)
            _ = ghostty_scene_renderer_release_frame(core.renderer, &frame)
        }

        let surface = Unmanaged<IOSurfaceRef>
            .fromOpaque(retainedSurface)
            .takeUnretainedValue()
        guard IOSurfaceGetWidth(surface) == Int(frame.width),
              IOSurfaceGetHeight(surface) == Int(frame.height),
              IOSurfaceGetPixelFormat(surface) == 0x4247_5241,
              IOSurfaceGetPlaneCount(surface) == 0,
              IOSurfaceGetBytesPerElement(surface) == 4,
              IOSurfaceGetBytesPerRow(surface) >= Int(frame.width) * 4 else {
            throw GhosttySemanticSceneRendererError.gpuFailure
        }
        try present(surface: surface, width: Int(frame.width), height: Int(frame.height))
        core.lastFrameSequence = frame.frame_sequence
    }

    private func present(
        surface: IOSurfaceRef,
        width: Int,
        height: Int
    ) throws {
        guard width > 0,
              height > 0,
              let drawable = presentationLayer.nextDrawable(),
              drawable.texture.width == width,
              drawable.texture.height == height else {
            throw GhosttySemanticSceneRendererError.gpuFailure
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard let source = device.makeTexture(
            descriptor: descriptor,
            iosurface: surface,
            plane: 0
        ),
        let commandBuffer = commandQueue.makeCommandBuffer(),
        let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw GhosttySemanticSceneRendererError.gpuFailure
        }
        blit.copy(
            from: source,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: drawable.texture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else {
            throw GhosttySemanticSceneRendererError.gpuFailure
        }
    }

    private func metrics(core: Core) throws -> GhosttySemanticSceneMetrics {
        var metrics = ghostty_scene_renderer_metrics_s()
        let status = ghostty_scene_renderer_get_metrics(core.renderer, &metrics)
        guard status == GHOSTTY_SCENE_RENDERER_SUCCESS else {
            throw Self.error(for: status)
        }
        return GhosttySemanticSceneMetrics(
            columns: Int(metrics.columns),
            rows: Int(metrics.rows),
            pixelWidth: Int(core.configuration.width),
            pixelHeight: Int(core.configuration.height),
            cellWidth: Int(metrics.cell_width),
            cellHeight: Int(metrics.cell_height),
            paddingTop: Int(metrics.padding_top),
            paddingRight: Int(metrics.padding_right),
            paddingBottom: Int(metrics.padding_bottom),
            paddingLeft: Int(metrics.padding_left)
        )
    }

    private static func error(
        for status: ghostty_scene_renderer_status_e
    ) -> GhosttySemanticSceneRendererError {
        switch status {
        case GHOSTTY_SCENE_RENDERER_BUSY:
            .rendererBusy
        case GHOSTTY_SCENE_RENDERER_INVALID_SCENE,
             GHOSTTY_SCENE_RENDERER_NO_SCENE:
            .invalidScene
        case GHOSTTY_SCENE_RENDERER_REPLAY_REJECTED:
            .rendererRejectedScene
        case GHOSTTY_SCENE_RENDERER_UNSUPPORTED_CAPABILITY,
             GHOSTTY_SCENE_RENDERER_UNSUPPORTED:
            .unsupportedScene
        case GHOSTTY_SCENE_RENDERER_OUT_OF_MEMORY,
             GHOSTTY_SCENE_RENDERER_LIMIT_EXCEEDED:
            .resourceExhausted
        case GHOSTTY_SCENE_RENDERER_GPU_ERROR:
            .gpuFailure
        default:
            .rendererUnavailable
        }
    }
}
#endif
