internal import CmuxTerminalCore
internal import GhosttyKit

/// C trampoline required by libghostty's renderer-thread callback API.
let terminalRendererEventCallback: @convention(c) (
    UnsafeMutableRawPointer?, ghostty_renderer_event_e
) -> Void = { userdata, event in
    guard let userdata else { return }
    let context = Unmanaged<GhosttySurfaceCallbackContext>
        .fromOpaque(userdata)
        .takeUnretainedValue()
    switch event {
    case GHOSTTY_RENDERER_EVENT_UPDATE_FRAME_END:
        context.rendererMailboxDidDrain()
    default:
        break
    }
}

/// C trampoline for exact tokened host-layer presentation.
let terminalRendererPresentedCallback: @convention(c) (
    UnsafeMutableRawPointer?, UInt64
) -> Void = { userdata, token in
    guard let userdata else { return }
    Unmanaged<GhosttySurfaceCallbackContext>
        .fromOpaque(userdata)
        .takeUnretainedValue()
        .rendererFrameDidPresent(token: token)
}

/// C trampoline for tokened presentation failures.
let terminalRendererFailedCallback: @convention(c) (
    UnsafeMutableRawPointer?, UInt64, ghostty_render_presentation_status_e
) -> Void = { userdata, token, status in
    guard let userdata else { return }
    Unmanaged<GhosttySurfaceCallbackContext>
        .fromOpaque(userdata)
        .takeUnretainedValue()
        .rendererFrameDidFail(token: token, status: status)
}
