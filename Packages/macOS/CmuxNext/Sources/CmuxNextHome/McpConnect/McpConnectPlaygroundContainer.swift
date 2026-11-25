#if DEBUG
import AppKit

/// DEBUG ONLY: the playground window's content view. It holds the playground, so the window owns
/// it and closing the window frees it (no static reference).
final class McpConnectPlaygroundContainer: NSView {
    var owner: AnyObject?
}
#endif
