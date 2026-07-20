import AppKit
import CmuxTerminalRenderer
import Darwin
import Foundation
import GhosttyKit
import IOSurface
import XPC

@MainActor
final class GhosttyRendererWorkerRuntime {
    enum Error: Swift.Error {
        case ghosttyInitializationFailed(Int32)
        case configurationCreationFailed
        case appCreationFailed
        case surfaceCreationFailed
        case invalidSurfaceConfiguration
    }

    private let listener: any RendererWorkerListening
    private var callbackContext: Unmanaged<GhosttyRendererCallbackContext>!
    nonisolated(unsafe) private let config: ghostty_config_t
    nonisolated(unsafe) private var app: ghostty_app_t!
    private var surfaces: [UUID: GhosttyRendererWorkerSurface] = [:]
    private var eventChannel: RendererWorkerMessage?

    init(listener: any RendererWorkerListening) throws {
        self.listener = listener

        let initializationResult = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        guard initializationResult == GHOSTTY_SUCCESS else {
            throw Error.ghosttyInitializationFailed(initializationResult)
        }
        guard let config = ghostty_config_new() else {
            throw Error.configurationCreationFailed
        }
        ghostty_config_load_default_files(config)
        ghostty_config_load_recursive_files(config)
        ghostty_config_finalize(config)
        self.config = config

        let callbackContext = Unmanaged.passRetained(
            GhosttyRendererCallbackContext(runtime: self)
        )
        self.callbackContext = callbackContext

        var runtimeConfiguration = ghostty_runtime_config_s()
        runtimeConfiguration.userdata = callbackContext.toOpaque()
        runtimeConfiguration.supports_selection_clipboard = false
        runtimeConfiguration.wakeup_cb = { userdata in
            guard let userdata else { return }
            Unmanaged<GhosttyRendererCallbackContext>
                .fromOpaque(userdata)
                .takeUnretainedValue()
                .requestTick()
        }
        runtimeConfiguration.action_cb = { _, target, action in
            guard target.tag == GHOSTTY_TARGET_SURFACE,
                  let surface = target.target.surface,
                  let userdata = ghostty_surface_userdata(surface) else {
                return false
            }
            let surfaceContext = Unmanaged<GhosttyRendererSurfaceCallbackContext>
                .fromOpaque(userdata)
                .takeUnretainedValue()
            return surfaceContext.runtime.performAction(target: target, action: action)
        }
        runtimeConfiguration.read_clipboard_cb = { _, _, _ in false }
        runtimeConfiguration.confirm_read_clipboard_cb = { _, _, _, _ in }
        runtimeConfiguration.write_clipboard_cb = { _, _, _, _, _ in }
        runtimeConfiguration.close_surface_cb = { userdata, processAlive in
            guard let userdata else { return }
            let surfaceContext = Unmanaged<GhosttyRendererSurfaceCallbackContext>
                .fromOpaque(userdata)
                .takeUnretainedValue()
            surfaceContext.runtime.requestClose(
                surfaceID: surfaceContext.identity.surfaceID,
                processAlive: processAlive
            )
        }
        runtimeConfiguration.tmux_control_cb = { _, _, _, _, _ in }

        guard let app = ghostty_app_new(&runtimeConfiguration, config) else {
            callbackContext.release()
            ghostty_config_free(config)
            throw Error.appCreationFailed
        }
        self.app = app
    }

    deinit {
        surfaces.removeAll()
        if let app {
            ghostty_app_free(app)
        }
        ghostty_config_free(config)
        callbackContext?.release()
    }

    func run() async {
        for await incoming in listener.messages {
            eventChannel = incoming
            do {
                try handle(incoming)
            } catch {
                sendFailure(String(describing: error))
            }
        }
    }

    func tick() {
        ghostty_app_tick(app)
    }

    func publishFrame(surfaceID: UUID) {
        guard let workerSurface = surfaces[surfaceID],
              let contents = workerSurface.view.layer?.contents else { return }
        let cfContents = contents as CFTypeRef
        guard CFGetTypeID(cfContents) == IOSurfaceGetTypeID() else { return }
        let ioSurface = contents as! IOSurfaceRef

        let message = RendererIPCCommand.surface(
            operation: .frame,
            identity: workerSurface.identity
        )
        let sequence = workerSurface.nextFrameSequence()
        xpc_dictionary_set_uint64(message, RendererIPCKey.sequence, sequence)
        xpc_dictionary_set_uint64(
            message,
            RendererIPCKey.width,
            UInt64(IOSurfaceGetWidth(ioSurface))
        )
        xpc_dictionary_set_uint64(
            message,
            RendererIPCKey.height,
            UInt64(IOSurfaceGetHeight(ioSurface))
        )
        xpc_dictionary_set_double(message, RendererIPCKey.scaleX, workerSurface.scaleX)
        xpc_dictionary_set_double(message, RendererIPCKey.scaleY, workerSurface.scaleY)
        xpc_dictionary_set_value(
            message,
            RendererIPCKey.ioSurface,
            IOSurfaceCreateXPCObject(ioSurface)
        )
        eventChannel?.send(RendererXPCObject(message))
    }

    nonisolated func sendProcessInput(surfaceID: UUID, data: Data) {
        Task { @MainActor in
            guard let workerSurface = surfaces[surfaceID] else { return }
            let message = RendererIPCCommand.surface(
                operation: .processInput,
                identity: workerSurface.identity
            )
            RendererIPCMessage.setData(data, forKey: RendererIPCKey.data, in: message)
            eventChannel?.send(RendererXPCObject(message))
        }
    }

    nonisolated func sendAction(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        guard target.tag == GHOSTTY_TARGET_SURFACE,
              let surface = target.target.surface,
              let userdata = ghostty_surface_userdata(surface) else { return false }
        let surfaceContext = Unmanaged<GhosttyRendererSurfaceCallbackContext>
            .fromOpaque(userdata)
            .takeUnretainedValue()
        let identity = surfaceContext.identity
        Task { @MainActor in
            let message = RendererIPCCommand.surface(operation: .action, identity: identity)
            xpc_dictionary_set_uint64(
                message,
                RendererIPCKey.action,
                UInt64(action.tag.rawValue)
            )
            eventChannel?.send(RendererXPCObject(message))
        }
        return false
    }

    nonisolated func sendCloseRequest(surfaceID: UUID, processAlive: Bool) {
        Task { @MainActor in
            guard let workerSurface = surfaces[surfaceID] else { return }
            let message = RendererIPCCommand.surface(
                operation: .action,
                identity: workerSurface.identity
            )
            xpc_dictionary_set_uint64(
                message,
                RendererIPCKey.action,
                UInt64(GHOSTTY_ACTION_CLOSE_TAB.rawValue)
            )
            xpc_dictionary_set_bool(message, RendererIPCKey.value, processAlive)
            eventChannel?.send(RendererXPCObject(message))
        }
    }

    private func handle(_ incoming: RendererWorkerMessage) throws {
        guard let operation = RendererIPCMessage.operation(in: incoming.message.value) else {
            throw Error.invalidSurfaceConfiguration
        }

        switch operation {
        case .hello, .ping:
            incoming.send(RendererXPCObject(RendererIPCMessage.make(
                operation == .ping ? .pong : .ready
            )))
        case .createSurface:
            try createSurface(from: incoming.message.value)
        case .destroySurface:
            guard let identity = identity(in: incoming.message.value) else { return }
            surfaces.removeValue(forKey: identity.surfaceID)
        case .resize:
            resize(from: incoming.message.value)
        case .focus:
            withSurface(incoming.message.value) { surface in
                ghostty_surface_set_focus(
                    surface.surface,
                    xpc_dictionary_get_bool(incoming.message.value, RendererIPCKey.value)
                )
            }
        case .occlusion:
            withSurface(incoming.message.value) { surface in
                ghostty_surface_set_occlusion(
                    surface.surface,
                    xpc_dictionary_get_bool(incoming.message.value, RendererIPCKey.value)
                )
            }
        case .key:
            key(from: incoming.message.value)
        case .text, .markedText:
            text(from: incoming.message.value, marked: operation == .markedText)
        case .unmarkText:
            withSurface(incoming.message.value) { surface in
                ghostty_surface_preedit(surface.surface, nil, 0)
            }
        case .mousePosition:
            withSurface(incoming.message.value) { surface in
                ghostty_surface_mouse_pos(
                    surface.surface,
                    xpc_dictionary_get_double(incoming.message.value, RendererIPCKey.positionX),
                    xpc_dictionary_get_double(incoming.message.value, RendererIPCKey.positionY),
                    ghostty_input_mods_e(UInt32(clamping: xpc_dictionary_get_uint64(
                        incoming.message.value,
                        RendererIPCKey.modifiers
                    )))
                )
            }
        case .mouseButton:
            withSurface(incoming.message.value) { surface in
                _ = ghostty_surface_mouse_button(
                    surface.surface,
                    ghostty_input_mouse_state_e(UInt32(clamping: xpc_dictionary_get_uint64(
                        incoming.message.value,
                        RendererIPCKey.action
                    ))),
                    ghostty_input_mouse_button_e(UInt32(clamping: xpc_dictionary_get_uint64(
                        incoming.message.value,
                        RendererIPCKey.button
                    ))),
                    ghostty_input_mods_e(UInt32(clamping: xpc_dictionary_get_uint64(
                        incoming.message.value,
                        RendererIPCKey.modifiers
                    )))
                )
            }
        case .mouseScroll:
            withSurface(incoming.message.value) { surface in
                ghostty_surface_mouse_scroll(
                    surface.surface,
                    xpc_dictionary_get_double(incoming.message.value, RendererIPCKey.positionX),
                    xpc_dictionary_get_double(incoming.message.value, RendererIPCKey.positionY),
                    ghostty_input_scroll_mods_t(xpc_dictionary_get_int64(
                        incoming.message.value,
                        RendererIPCKey.modifiers
                    ))
                )
            }
        case .mousePressure:
            withSurface(incoming.message.value) { surface in
                ghostty_surface_mouse_pressure(
                    surface.surface,
                    UInt32(clamping: xpc_dictionary_get_uint64(
                        incoming.message.value,
                        RendererIPCKey.action
                    )),
                    xpc_dictionary_get_double(incoming.message.value, RendererIPCKey.pressure)
                )
            }
        case .processOutput:
            withSurface(incoming.message.value) { surface in
                guard let data = RendererIPCMessage.data(
                    forKey: RendererIPCKey.data,
                    in: incoming.message.value
                ) else { return }
                data.withUnsafeBytes { bytes in
                    guard let base = bytes.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
                    ghostty_surface_process_output(surface.surface, base, UInt(bytes.count))
                }
            }
        case .renderNow:
            withSurface(incoming.message.value) { surface in
                ghostty_surface_render_now(surface.surface)
            }
        case .action:
            guard let action = xpc_dictionary_get_string(
                incoming.message.value,
                RendererIPCKey.text
            ) else { return }
            withSurface(incoming.message.value) { surface in
                _ = ghostty_surface_binding_action(
                    surface.surface,
                    action,
                    UInt(strlen(action))
                )
            }
        case .updateConfiguration:
            let flags = xpc_dictionary_get_uint64(
                incoming.message.value,
                RendererIPCKey.flags
            )
            if flags == 1 {
                withSurface(incoming.message.value) { surface in
                    ghostty_surface_set_color_scheme(
                        surface.surface,
                        ghostty_color_scheme_e(UInt32(clamping: xpc_dictionary_get_uint64(
                            incoming.message.value,
                            RendererIPCKey.value
                        )))
                    )
                }
            } else if flags == 2 {
                reloadConfiguration(for: incoming.message.value)
            }
        case .shutdown:
            surfaces.removeAll()
            Darwin.exit(EXIT_SUCCESS)
        default:
            sendFailure("unsupported operation \(operation.rawValue)")
        }
    }

    private func createSurface(from message: xpc_object_t) throws {
        guard let data = RendererIPCMessage.data(
            forKey: RendererIPCKey.configuration,
            in: message
        ) else { throw Error.invalidSurfaceConfiguration }
        let configuration = try PropertyListDecoder().decode(
            RendererSurfaceConfiguration.self,
            from: data
        )
        guard surfaces[configuration.identity.surfaceID] == nil else { return }
        let surface = try GhosttyRendererWorkerSurface(
            app: app,
            configuration: configuration,
            runtimeContext: callbackContext.takeUnretainedValue()
        )
        surfaces[configuration.identity.surfaceID] = surface
        let created = RendererIPCCommand.surface(
            operation: .surfaceCreated,
            identity: configuration.identity
        )
        eventChannel?.send(RendererXPCObject(created))
    }

    private func reloadConfiguration(for message: xpc_object_t) {
        guard let updatedConfiguration = ghostty_config_new() else { return }
        ghostty_config_load_default_files(updatedConfiguration)
        ghostty_config_load_recursive_files(updatedConfiguration)
        ghostty_config_finalize(updatedConfiguration)
        withSurface(message) { surface in
            ghostty_surface_update_config(surface.surface, updatedConfiguration)
        }
        ghostty_config_free(updatedConfiguration)
    }

    private func resize(from message: xpc_object_t) {
        withSurface(message) { surface in
            let width = UInt32(clamping: xpc_dictionary_get_uint64(
                message,
                RendererIPCKey.width
            ))
            let height = UInt32(clamping: xpc_dictionary_get_uint64(
                message,
                RendererIPCKey.height
            ))
            let scaleX = xpc_dictionary_get_double(message, RendererIPCKey.scaleX)
            let scaleY = xpc_dictionary_get_double(message, RendererIPCKey.scaleY)
            surface.view.frame = NSRect(
                x: 0,
                y: 0,
                width: Double(width) / max(scaleX, 1),
                height: Double(height) / max(scaleY, 1)
            )
            surface.scaleX = scaleX
            surface.scaleY = scaleY
            ghostty_surface_set_content_scale(surface.surface, scaleX, scaleY)
            ghostty_surface_set_size(surface.surface, width, height)
        }
    }

    private func key(from message: xpc_object_t) {
        withSurface(message) { surface in
            var event = ghostty_input_key_s()
            event.action = ghostty_input_action_e(
                UInt32(clamping: xpc_dictionary_get_uint64(
                    message,
                    RendererIPCKey.action
                ))
            )
            event.mods = ghostty_input_mods_e(
                UInt32(clamping: xpc_dictionary_get_uint64(
                    message,
                    RendererIPCKey.modifiers
                ))
            )
            event.consumed_mods = ghostty_input_mods_e(
                UInt32(clamping: xpc_dictionary_get_uint64(
                    message,
                    RendererIPCKey.consumedModifiers
                ))
            )
            event.keycode = UInt32(clamping: xpc_dictionary_get_uint64(
                message,
                RendererIPCKey.keycode
            ))
            event.unshifted_codepoint = UInt32(clamping: xpc_dictionary_get_uint64(
                message,
                RendererIPCKey.unshiftedCodepoint
            ))
            event.composing = xpc_dictionary_get_bool(message, RendererIPCKey.composing)
            if let text = xpc_dictionary_get_string(message, RendererIPCKey.text) {
                event.text = text
                _ = ghostty_surface_key(surface.surface, event)
            } else {
                _ = ghostty_surface_key(surface.surface, event)
            }
        }
    }

    private func text(from message: xpc_object_t, marked: Bool) {
        guard let text = xpc_dictionary_get_string(message, RendererIPCKey.text) else { return }
        withSurface(message) { surface in
            let count = strlen(text)
            if marked {
                ghostty_surface_preedit(surface.surface, text, UInt(count))
            } else {
                ghostty_surface_text_input(surface.surface, text, UInt(count))
            }
        }
    }

    private func withSurface(
        _ message: xpc_object_t,
        _ body: (GhosttyRendererWorkerSurface) -> Void
    ) {
        guard let identity = identity(in: message),
              let surface = surfaces[identity.surfaceID],
              surface.identity == identity else { return }
        body(surface)
    }

    private func identity(in message: xpc_object_t) -> RendererSurfaceIdentity? {
        guard let workspaceID = RendererIPCMessage.uuid(
            forKey: RendererIPCKey.workspaceID,
            in: message
        ), let surfaceID = RendererIPCMessage.uuid(
            forKey: RendererIPCKey.surfaceID,
            in: message
        ) else { return nil }
        return RendererSurfaceIdentity(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            generation: xpc_dictionary_get_uint64(message, RendererIPCKey.generation)
        )
    }

    private func sendFailure(_ error: String) {
        let message = RendererIPCMessage.make(.failure)
        xpc_dictionary_set_string(message, RendererIPCKey.error, error)
        eventChannel?.send(RendererXPCObject(message))
    }
}
