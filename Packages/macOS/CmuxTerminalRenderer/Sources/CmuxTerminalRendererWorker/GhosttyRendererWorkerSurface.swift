import AppKit
import CmuxTerminalRenderer
import CoreGraphics
import Foundation
import GhosttyKit

@MainActor
final class GhosttyRendererWorkerSurface {
    let identity: RendererSurfaceIdentity
    let view: NSView
    nonisolated(unsafe) let surface: ghostty_surface_t
    var scaleX: Double
    var scaleY: Double

    private let callbackContext: Unmanaged<GhosttyRendererSurfaceCallbackContext>
    private var frameSequence: UInt64 = 0

    init(
        app: ghostty_app_t,
        configuration: RendererSurfaceConfiguration,
        runtimeContext: GhosttyRendererCallbackContext
    ) throws {
        identity = configuration.identity
        scaleX = configuration.scaleX
        scaleY = configuration.scaleY
        let pointWidth = Double(configuration.pixelWidth) / max(configuration.scaleX, 1)
        let pointHeight = Double(configuration.pixelHeight) / max(configuration.scaleY, 1)
        let view = NSView(frame: NSRect(x: 0, y: 0, width: pointWidth, height: pointHeight))
        self.view = view

        let callbackContext = Unmanaged.passRetained(
            GhosttyRendererSurfaceCallbackContext(
                identity: configuration.identity,
                runtime: runtimeContext
            )
        )
        self.callbackContext = callbackContext

        var surfaceConfiguration = ghostty_surface_config_new()
        surfaceConfiguration.platform_tag = GHOSTTY_PLATFORM_MACOS
        surfaceConfiguration.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(
                nsview: Unmanaged.passUnretained(view).toOpaque()
            )
        )
        surfaceConfiguration.userdata = callbackContext.toOpaque()
        surfaceConfiguration.scale_factor = configuration.scaleX
        surfaceConfiguration.font_size = configuration.fontSize
        surfaceConfiguration.wait_after_command = configuration.waitAfterCommand
        surfaceConfiguration.context = ghostty_surface_context_e(configuration.context)
        surfaceConfiguration.renderer_event_cb = ghosttyRendererWorkerEventCallback

        if configuration.manualIO {
            surfaceConfiguration.io_mode = GHOSTTY_SURFACE_IO_MANUAL
            surfaceConfiguration.io_write_cb = ghosttyRendererWorkerIOWriteCallback
            surfaceConfiguration.io_write_userdata = callbackContext.toOpaque()
        }

        var environmentStorage: [(UnsafeMutablePointer<CChar>, UnsafeMutablePointer<CChar>)] = []
        var environment = configuration.environment.compactMap { key, value -> ghostty_env_var_s? in
            guard let keyPointer = strdup(key), let valuePointer = strdup(value) else { return nil }
            environmentStorage.append((keyPointer, valuePointer))
            return ghostty_env_var_s(key: keyPointer, value: valuePointer)
        }
        defer {
            for (key, value) in environmentStorage {
                free(key)
                free(value)
            }
        }

        let createdSurface = configuration.command.withOptionalCString { command in
            surfaceConfiguration.command = command
            return configuration.workingDirectory.withOptionalCString { workingDirectory in
                surfaceConfiguration.working_directory = workingDirectory
                return configuration.initialInput.withOptionalCString { initialInput in
                    surfaceConfiguration.initial_input = initialInput
                    if environment.isEmpty {
                        return ghostty_surface_new(app, &surfaceConfiguration)
                    }
                    return environment.withUnsafeMutableBufferPointer { buffer in
                        surfaceConfiguration.env_vars = buffer.baseAddress
                        surfaceConfiguration.env_var_count = buffer.count
                        return ghostty_surface_new(app, &surfaceConfiguration)
                    }
                }
            }
        }

        guard let createdSurface else {
            callbackContext.release()
            throw GhosttyRendererWorkerRuntime.Error.surfaceCreationFailed
        }
        surface = createdSurface
        ghostty_surface_set_display_id(surface, CGMainDisplayID())
        ghostty_surface_set_occlusion(surface, true)
        ghostty_surface_set_content_scale(surface, configuration.scaleX, configuration.scaleY)
        ghostty_surface_set_size(surface, configuration.pixelWidth, configuration.pixelHeight)
    }

    deinit {
        ghostty_surface_free(surface)
        callbackContext.release()
    }

    func nextFrameSequence() -> UInt64 {
        frameSequence &+= 1
        return frameSequence
    }
}

private extension Optional where Wrapped == String {
    func withOptionalCString<T>(_ body: (UnsafePointer<CChar>?) -> T) -> T {
        switch self {
        case .some(let value):
            value.withCString(body)
        case .none:
            body(nil)
        }
    }
}

private func ghosttyRendererWorkerEventCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ event: ghostty_renderer_event_e
) {
    guard event == GHOSTTY_RENDERER_EVENT_FRAME_COMPLETED,
          let userdata else { return }
    let context = Unmanaged<GhosttyRendererSurfaceCallbackContext>
        .fromOpaque(userdata)
        .takeUnretainedValue()
    context.runtime.requestFrame(surfaceID: context.identity.surfaceID)
}

private func ghosttyRendererWorkerIOWriteCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ bytes: UnsafePointer<CChar>?,
    _ count: UInt
) {
    guard let userdata, let bytes, count > 0 else { return }
    let context = Unmanaged<GhosttyRendererSurfaceCallbackContext>
        .fromOpaque(userdata)
        .takeUnretainedValue()
    context.runtime.processInput(
        surfaceID: context.identity.surfaceID,
        data: Data(bytes: bytes, count: Int(count))
    )
}
