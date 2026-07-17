internal import CmuxTerminalRenderTransport
internal import Darwin
internal import Foundation
internal import CmuxGhosttyRenderWorkerGhosttyKit
internal import IOSurface

/// Runs the AppKit-free Ghostty render worker on the current executable.
///
/// The parent launches this before initializing `NSApplication`. The calling
/// thread owns the blocking control read while every libghostty call is
/// serialized on `engineQueue`. Metal completion callbacks use only the
/// nonblocking Mach frame sender.
public func runGhosttyRenderWorker() -> Never {
    let channel = TerminalRenderMessageChannel(
        readDescriptor: STDIN_FILENO,
        writeDescriptor: STDOUT_FILENO
    )
    let engine = GhosttyRenderWorkerEngine(channel: channel)
    let status = engine.run()
    Darwin.exit(status)
}

private final class GhosttyRenderWorkerEngine: @unchecked Sendable {
    private let channel: TerminalRenderMessageChannel
    private let engineQueue = DispatchQueue(
        label: "dev.cmux.ghostty-render-worker.engine",
        qos: .userInteractive
    )
    private var app: ghostty_app_t?
    private var configuration: ghostty_config_t?
    private var configurationRevision: UInt64 = 0
    private var frameSender: TerminalRenderFrameSender?
    private var workerGeneration: UInt64 = 0
    private var surfaces: [UUID: WorkerSurface] = [:]
    private var shuttingDown = false

    init(channel: TerminalRenderMessageChannel) {
        self.channel = channel
    }

    func run() -> Int32 {
        while let payload = channel.receive() {
            guard let command = try? TerminalRenderControlCodec.decodeCommand(payload) else {
                send(.failure("render worker rejected an invalid control message"))
                continue
            }
            let shouldContinue = engineQueue.sync { handle(command) }
            if !shouldContinue { break }
        }
        engineQueue.sync { teardown() }
        return 0
    }

    private func handle(_ command: TerminalRenderWorkerCommand) -> Bool {
        switch command {
        case let .initialize(version, generation, endpoint, snapshot):
            guard app == nil else {
                send(.failure("render worker was initialized more than once"))
                return true
            }
            guard version == TerminalRenderProtocol.currentVersion else {
                send(.failure("render worker protocol version mismatch"))
                return false
            }
            do {
                try initialize(
                    workerGeneration: generation,
                    endpoint: endpoint,
                    configurationSnapshot: snapshot
                )
                send(.initialized(
                    protocolVersion: version,
                    workerGeneration: generation,
                    processIdentifier: getpid()
                ))
            } catch {
                send(.failure("render worker initialization failed: \(error)"))
                return false
            }

        case let .replaceConfiguration(snapshot):
            guard app != nil else {
                send(.failure("render worker received configuration before initialization"))
                return true
            }
            guard snapshot.revision > configurationRevision else { return true }
            do {
                try replaceConfiguration(snapshot)
            } catch {
                send(.failure("render worker configuration failed: \(error)"))
            }

        case let .createSurface(descriptor):
            do {
                try createSurface(descriptor, emitCreated: true)
            } catch {
                send(.failure("render surface \(descriptor.id) creation failed: \(error)"))
            }

        case let .mutateSurface(id, generation, mutation):
            guard let surface = surfaces[id], surface.descriptor.generation == generation else {
                return true
            }
            apply(mutation, to: surface)

        case let .resynchronizeSurface(descriptor, nextOutputSequence, screenTailVT):
            do {
                try createSurface(descriptor, emitCreated: false)
                guard let surface = surfaces[descriptor.id] else {
                    throw GhosttyRenderWorkerError.surfaceCreationFailed
                }
                if !screenTailVT.isEmpty {
                    process(screenTailVT, through: surface.handle)
                }
                surface.nextOutputSequence = nextOutputSequence
                ghostty_surface_refresh(surface.handle)
                send(.surfaceCreated(id: descriptor.id, generation: descriptor.generation))
                send(.outputApplied(
                    id: descriptor.id,
                    generation: descriptor.generation,
                    nextSequence: nextOutputSequence
                ))
            } catch {
                send(.failure("render surface \(descriptor.id) resynchronization failed: \(error)"))
            }

        case let .destroySurface(id, generation):
            guard surfaces[id]?.descriptor.generation == generation else { return true }
            destroySurface(id: id, emitDestroyed: true)

        case .shutdown:
            shuttingDown = true
            return false
        }
        return true
    }

    private func initialize(
        workerGeneration: UInt64,
        endpoint: TerminalRenderFrameEndpoint,
        configurationSnapshot: TerminalRenderConfigurationSnapshot
    ) throws {
        let result = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        guard result == GHOSTTY_SUCCESS else {
            throw GhosttyRenderWorkerError.ghosttyInitializationFailed(result)
        }

        let config = try makeConfiguration(configurationSnapshot)
        do {
            frameSender = try TerminalRenderFrameSender(endpoint: endpoint)
        } catch {
            ghostty_config_free(config)
            throw error
        }

        var runtime = ghostty_runtime_config_s()
        runtime.userdata = Unmanaged.passUnretained(self).toOpaque()
        runtime.supports_selection_clipboard = false
        runtime.wakeup_cb = { userdata in
            guard let userdata else { return }
            let engine = Unmanaged<GhosttyRenderWorkerEngine>
                .fromOpaque(userdata)
                .takeUnretainedValue()
            engine.scheduleTick()
        }
        runtime.action_cb = { _, _, _ in true }
        runtime.read_clipboard_cb = cmuxRenderWorkerReadClipboardCallback
        runtime.confirm_read_clipboard_cb = { _, _, _, _ in }
        runtime.write_clipboard_cb = { _, _, _, _, _ in }
        runtime.close_surface_cb = { _, _ in }
        runtime.tmux_control_cb = { _, _, _, _, _ in }

        guard let createdApp = ghostty_app_new(&runtime, config) else {
            ghostty_config_free(config)
            throw GhosttyRenderWorkerError.appCreationFailed
        }
        app = createdApp
        configuration = config
        configurationRevision = configurationSnapshot.revision
        self.workerGeneration = workerGeneration
    }

    private func makeConfiguration(
        _ snapshot: TerminalRenderConfigurationSnapshot
    ) throws -> ghostty_config_t {
        guard let config = ghostty_config_new() else {
            throw GhosttyRenderWorkerError.configurationCreationFailed
        }
        snapshot.contents.withCString { contents in
            "cmux-render-worker".withCString { source in
                ghostty_config_load_string(
                    config,
                    contents,
                    UInt(snapshot.contents.utf8.count),
                    source
                )
            }
        }
        ghostty_config_finalize(config)
        return config
    }

    private func replaceConfiguration(
        _ snapshot: TerminalRenderConfigurationSnapshot
    ) throws {
        guard let app else { throw GhosttyRenderWorkerError.notInitialized }
        let newConfiguration = try makeConfiguration(snapshot)
        ghostty_app_update_config(app, newConfiguration)
        let oldConfiguration = configuration
        configuration = newConfiguration
        configurationRevision = snapshot.revision
        if let oldConfiguration { ghostty_config_free(oldConfiguration) }
    }

    private func createSurface(
        _ descriptor: TerminalRenderSurfaceDescriptor,
        emitCreated: Bool
    ) throws {
        guard let app, let frameSender else {
            throw GhosttyRenderWorkerError.notInitialized
        }
        destroySurface(id: descriptor.id, emitDestroyed: false)

        let presentation = WorkerSurfacePresentation(
            sender: frameSender,
            surfaceID: descriptor.id,
            workerGeneration: workerGeneration,
            surfaceGeneration: descriptor.generation
        )
        let retainedPresentation = Unmanaged.passRetained(presentation)
        var surfaceConfig = ghostty_surface_config_new()
        surfaceConfig.platform_tag = GHOSTTY_PLATFORM_METAL_EXTERNAL
        surfaceConfig.platform = ghostty_platform_u(
            metal_external: ghostty_platform_metal_external_s(
                userdata: retainedPresentation.toOpaque(),
                present: cmuxRenderWorkerPresentCallback
            )
        )
        surfaceConfig.userdata = retainedPresentation.toOpaque()
        surfaceConfig.scale_factor = max(descriptor.scaleX, descriptor.scaleY)
        surfaceConfig.font_size = descriptor.fontSize
        surfaceConfig.context = surfaceContext(rawValue: descriptor.context)
        surfaceConfig.io_mode = GHOSTTY_SURFACE_IO_MANUAL
        surfaceConfig.io_write_cb = { _, _, _ in }
        surfaceConfig.io_write_userdata = nil

        guard let handle = ghostty_surface_new(app, &surfaceConfig) else {
            retainedPresentation.release()
            throw GhosttyRenderWorkerError.surfaceCreationFailed
        }
        let workerSurface = WorkerSurface(
            descriptor: descriptor,
            handle: handle,
            presentation: retainedPresentation
        )
        surfaces[descriptor.id] = workerSurface
        ghostty_surface_set_content_scale(handle, descriptor.scaleX, descriptor.scaleY)
        ghostty_surface_set_size(handle, max(descriptor.width, 1), max(descriptor.height, 1))
        ghostty_surface_set_occlusion(handle, true)
        _ = ghostty_surface_set_renderer_realized(handle, true)
        ghostty_surface_refresh(handle)
        if emitCreated {
            send(.surfaceCreated(id: descriptor.id, generation: descriptor.generation))
        }
    }

    private func apply(
        _ mutation: TerminalRenderSurfaceMutation,
        to surface: WorkerSurface
    ) {
        let handle = surface.handle
        switch mutation {
        case let .processOutput(sequence, bytes):
            applyOutput(sequence: sequence, bytes: bytes, to: surface)
        case let .resize(width, height):
            ghostty_surface_set_size(handle, max(width, 1), max(height, 1))
            send(.resizeApplied(
                id: surface.descriptor.id,
                generation: surface.descriptor.generation,
                width: width,
                height: height
            ))
        case let .contentScale(x, y):
            ghostty_surface_set_content_scale(handle, x, y)
        case let .focus(focused):
            ghostty_surface_set_focus(handle, focused)
        case let .occlusion(visible):
            ghostty_surface_set_occlusion(handle, visible)
        case let .colorScheme(rawValue):
            ghostty_surface_set_color_scheme(handle, colorScheme(rawValue: rawValue))
        case let .rendererRealized(realized):
            _ = ghostty_surface_set_renderer_realized(handle, realized)
        case .refresh:
            ghostty_surface_refresh(handle)
        case let .preedit(text, _, _):
            guard let text else {
                ghostty_surface_preedit(handle, nil, 0)
                return
            }
            text.withCString { ghostty_surface_preedit(handle, $0, UInt(text.utf8.count)) }
        case let .mousePosition(x, y, modifiers):
            ghostty_surface_mouse_pos(
                handle,
                x,
                y,
                ghostty_input_mods_e(rawValue: modifiers)
            )
        case let .mouseButton(state, button, modifiers):
            _ = ghostty_surface_mouse_button(
                handle,
                ghostty_input_mouse_state_e(rawValue: UInt32(bitPattern: state)),
                ghostty_input_mouse_button_e(rawValue: UInt32(bitPattern: button)),
                ghostty_input_mods_e(rawValue: modifiers)
            )
        case let .mouseScroll(deltaX, deltaY, modifiers):
            ghostty_surface_mouse_scroll(handle, deltaX, deltaY, Int32(bitPattern: modifiers))
        case .clearSelection:
            _ = ghostty_surface_clear_selection(handle)
        case let .bindingAction(action):
            action.withCString {
                _ = ghostty_surface_binding_action(handle, $0, UInt(action.utf8.count))
            }
        }
    }

    private func applyOutput(
        sequence: UInt64,
        bytes: Data,
        to surface: WorkerSurface
    ) {
        let expected = surface.nextOutputSequence
        let end = sequence &+ UInt64(bytes.count)
        if end <= expected {
            sendOutputApplied(for: surface)
            return
        }
        guard sequence <= expected else {
            send(.failure(
                "render surface \(surface.descriptor.id) output gap: expected \(expected), received \(sequence)"
            ))
            return
        }
        let offset = Int(expected - sequence)
        let suffix = offset == 0 ? bytes : Data(bytes.dropFirst(offset))
        process(suffix, through: surface.handle)
        surface.nextOutputSequence = expected &+ UInt64(suffix.count)
        sendOutputApplied(for: surface)
    }

    private func process(_ data: Data, through surface: ghostty_surface_t) {
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
            ghostty_surface_process_output(surface, base, UInt(bytes.count))
        }
    }

    private func sendOutputApplied(for surface: WorkerSurface) {
        send(.outputApplied(
            id: surface.descriptor.id,
            generation: surface.descriptor.generation,
            nextSequence: surface.nextOutputSequence
        ))
    }

    private func destroySurface(id: UUID, emitDestroyed: Bool) {
        guard let surface = surfaces.removeValue(forKey: id) else { return }
        ghostty_surface_free(surface.handle)
        surface.presentation.release()
        if emitDestroyed {
            send(.surfaceDestroyed(id: id, generation: surface.descriptor.generation))
        }
    }

    private func scheduleTick() {
        engineQueue.async { [weak self] in
            guard let self, !self.shuttingDown, let app = self.app else { return }
            ghostty_app_tick(app)
        }
    }

    private func send(_ event: TerminalRenderWorkerEvent) {
        guard let encoded = try? TerminalRenderControlCodec.encode(event) else { return }
        try? channel.send(encoded)
    }

    private func teardown() {
        shuttingDown = true
        for id in Array(surfaces.keys) {
            destroySurface(id: id, emitDestroyed: false)
        }
        if let app {
            ghostty_app_free(app)
            self.app = nil
        }
        if let configuration {
            ghostty_config_free(configuration)
            self.configuration = nil
        }
        frameSender = nil
    }
}

private final class WorkerSurface {
    let descriptor: TerminalRenderSurfaceDescriptor
    let handle: ghostty_surface_t
    let presentation: Unmanaged<WorkerSurfacePresentation>
    var nextOutputSequence: UInt64 = 0

    init(
        descriptor: TerminalRenderSurfaceDescriptor,
        handle: ghostty_surface_t,
        presentation: Unmanaged<WorkerSurfacePresentation>
    ) {
        self.descriptor = descriptor
        self.handle = handle
        self.presentation = presentation
    }
}

private final class WorkerSurfacePresentation: @unchecked Sendable {
    private let sender: TerminalRenderFrameSender
    private let surfaceID: UUID
    private let workerGeneration: UInt64
    private let surfaceGeneration: UInt64
    private let lock = NSLock()
    private var nextFrameSequence: UInt64 = 1

    init(
        sender: TerminalRenderFrameSender,
        surfaceID: UUID,
        workerGeneration: UInt64,
        surfaceGeneration: UInt64
    ) {
        self.sender = sender
        self.surfaceID = surfaceID
        self.workerGeneration = workerGeneration
        self.surfaceGeneration = surfaceGeneration
    }

    func present(_ surface: IOSurfaceRef, width: UInt32, height: UInt32) {
        let sequence = lock.withLock { () -> UInt64 in
            defer { nextFrameSequence &+= 1 }
            return nextFrameSequence
        }
        _ = try? sender.send(
            surface: surface,
            metadata: TerminalRenderFrameMetadata(
                surfaceID: surfaceID,
                workerGeneration: workerGeneration,
                surfaceGeneration: surfaceGeneration,
                frameSequence: sequence,
                width: width,
                height: height
            )
        )
    }
}

private let cmuxRenderWorkerPresentCallback: ghostty_metal_external_present_cb = {
    userdata,
    iosurface,
    width,
    height in
    guard let userdata, let iosurface else { return }
    let presentation = Unmanaged<WorkerSurfacePresentation>
        .fromOpaque(userdata)
        .takeUnretainedValue()
    let surface = Unmanaged<IOSurfaceRef>
        .fromOpaque(iosurface)
        .takeUnretainedValue()
    presentation.present(surface, width: width, height: height)
}

private let cmuxRenderWorkerReadClipboardCallback: @convention(c) (
    UnsafeMutableRawPointer?,
    ghostty_clipboard_e,
    UnsafeMutableRawPointer?
) -> Bool = { _, _, _ in false }

private func surfaceContext(rawValue: Int32) -> ghostty_surface_context_e {
    switch rawValue {
    case Int32(GHOSTTY_SURFACE_CONTEXT_TAB.rawValue): GHOSTTY_SURFACE_CONTEXT_TAB
    case Int32(GHOSTTY_SURFACE_CONTEXT_SPLIT.rawValue): GHOSTTY_SURFACE_CONTEXT_SPLIT
    default: GHOSTTY_SURFACE_CONTEXT_WINDOW
    }
}

private func colorScheme(rawValue: Int32) -> ghostty_color_scheme_e {
    switch rawValue {
    case Int32(GHOSTTY_COLOR_SCHEME_LIGHT.rawValue): GHOSTTY_COLOR_SCHEME_LIGHT
    case Int32(GHOSTTY_COLOR_SCHEME_DARK.rawValue): GHOSTTY_COLOR_SCHEME_DARK
    default: GHOSTTY_COLOR_SCHEME_LIGHT
    }
}

private enum GhosttyRenderWorkerError: Error {
    case ghosttyInitializationFailed(Int32)
    case configurationCreationFailed
    case appCreationFailed
    case surfaceCreationFailed
    case notInitialized
}
