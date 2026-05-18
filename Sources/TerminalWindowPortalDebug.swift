import AppKit

#if DEBUG
func portalDebugToken(_ view: NSView?) -> String {
    guard let view else { return "nil" }
    let ptr = Unmanaged.passUnretained(view).toOpaque()
    return String(describing: ptr)
}

func portalDebugFrame(_ rect: NSRect) -> String {
    String(format: "%.1f,%.1f %.1fx%.1f", rect.origin.x, rect.origin.y, rect.size.width, rect.size.height)
}

func portalDebugFrameInWindow(_ view: NSView?) -> String {
    guard let view else { return "nil" }
    guard view.window != nil else { return "no-window" }
    return portalDebugFrame(view.convert(view.bounds, to: nil))
}
#endif
