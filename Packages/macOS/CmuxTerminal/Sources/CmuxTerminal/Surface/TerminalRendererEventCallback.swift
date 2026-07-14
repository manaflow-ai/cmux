internal import CmuxTerminalCore
internal import GhosttyKit

let terminalRendererEventCallback: @convention(c) (
    UnsafeMutableRawPointer?,
    ghostty_renderer_event_e
) -> Void = { userdata, event in
    guard let userdata else { return }
    let context = Unmanaged<GhosttySurfaceCallbackContext>
        .fromOpaque(userdata)
        .takeUnretainedValue()
    context.recordRendererEvent(event)
}
