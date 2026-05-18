import CoreText
import Darwin
import Foundation

struct CmuxSurfaceConfigTemplate {
    var fontSize: Float32 = 0
    var workingDirectory: String?
    var command: String?
    var environmentVariables: [String: String] = [:]
    var initialInput: String?
    var waitAfterCommand: Bool = false

    init() {}

    init(cConfig: ghostty_surface_config_s) {
        fontSize = cConfig.font_size
        if let workingDirectory = cConfig.working_directory {
            self.workingDirectory = String(cString: workingDirectory, encoding: .utf8)
        }
        if let command = cConfig.command {
            self.command = String(cString: command, encoding: .utf8)
        }
        if let initialInput = cConfig.initial_input {
            self.initialInput = String(cString: initialInput, encoding: .utf8)
        }
        if cConfig.env_var_count > 0, let envVars = cConfig.env_vars {
            for index in 0..<Int(cConfig.env_var_count) {
                let envVar = envVars[index]
                if let key = String(cString: envVar.key, encoding: .utf8),
                   let value = String(cString: envVar.value, encoding: .utf8) {
                    environmentVariables[key] = value
                }
            }
        }
        waitAfterCommand = cConfig.wait_after_command
    }
}

func cmuxSurfaceContextName(_ context: ghostty_surface_context_e) -> String {
    switch context {
    case GHOSTTY_SURFACE_CONTEXT_WINDOW:
        return "window"
    case GHOSTTY_SURFACE_CONTEXT_TAB:
        return "tab"
    case GHOSTTY_SURFACE_CONTEXT_SPLIT:
        return "split"
    default:
        return "unknown(\(context))"
    }
}

private func cmuxPointerAppearsLive(_ pointer: UnsafeMutableRawPointer?) -> Bool {
    guard let pointer,
          malloc_zone_from_ptr(pointer) != nil else {
        return false
    }
    return malloc_size(pointer) > 0
}

func cmuxSurfacePointerAppearsLive(_ surface: ghostty_surface_t) -> Bool {
    // Best-effort check: reject pointers that no longer belong to an active
    // malloc zone allocation. A Swift wrapper around `ghostty_surface_t` can
    // remain non-nil after the backing native surface has already been freed.
    cmuxPointerAppearsLive(surface)
}

func cmuxCurrentSurfaceFontSizePoints(_ surface: ghostty_surface_t) -> Float? {
    guard cmuxSurfacePointerAppearsLive(surface) else {
        return nil
    }

    guard let quicklookFont = ghostty_surface_quicklook_font(surface) else {
        return nil
    }

    let ctFont = Unmanaged<CTFont>.fromOpaque(quicklookFont).takeUnretainedValue()
    let points = Float(CTFontGetSize(ctFont))
    guard points > 0 else { return nil }
    return points
}

func cmuxInheritedSurfaceConfig(
    sourceSurface: ghostty_surface_t,
    context: ghostty_surface_context_e
) -> CmuxSurfaceConfigTemplate {
    let inherited = ghostty_surface_inherited_config(sourceSurface, context)
    var config = CmuxSurfaceConfigTemplate(cConfig: inherited)

    // Make runtime zoom inheritance explicit, even when Ghostty's
    // inherit-font-size config is disabled.
    let runtimePoints = cmuxCurrentSurfaceFontSizePoints(sourceSurface)
    if let points = runtimePoints {
        config.fontSize = points
    }

#if DEBUG
    let inheritedText = String(format: "%.2f", inherited.font_size)
    let runtimeText = runtimePoints.map { String(format: "%.2f", $0) } ?? "nil"
    let finalText = String(format: "%.2f", config.fontSize)
    cmuxDebugLog(
        "zoom.inherit context=\(cmuxSurfaceContextName(context)) " +
        "inherited=\(inheritedText) runtime=\(runtimeText) final=\(finalText)"
    )
#endif

    return config
}
