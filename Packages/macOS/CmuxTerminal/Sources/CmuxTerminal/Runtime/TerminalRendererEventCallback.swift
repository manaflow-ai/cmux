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
        // TEMP DIAGNOSTIC: consume the notice on every event kind.
        context.rendererFrameDidEnd()
    case GHOSTTY_RENDERER_EVENT_DRAW_FRAME_END:
        // A reveal of unchanged terminal content draws without a state
        // update, so the first-frame notice must key on the draw event.
        context.rendererFrameDidEnd()
    default:
        context.rendererFrameDidEnd()
    }
}
