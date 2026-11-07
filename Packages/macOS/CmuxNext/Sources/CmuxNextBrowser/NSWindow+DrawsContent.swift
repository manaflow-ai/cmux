public import AppKit

extension NSUserInterfaceItemIdentifier {
    /// The identifier of every agent render window (`AgentRenderPanel`), the
    /// off-screen window that keeps a hidden tab an agent drives rendering.
    public static let agentRenderWindow = NSUserInterfaceItemIdentifier("cmux.agentRenderWindow")
}

extension NSWindow {
    /// Whether this window draws its content now.
    ///
    /// True for a window on screen that is not minimized and not fully
    /// covered, and for an agent render window (it renders off screen with
    /// occlusion detection off). WebKit pauses animation frames and slows
    /// timers in a window that is not drawn.
    public var drawsContent: Bool {
        identifier == .agentRenderWindow || (isVisible && !isMiniaturized && occlusionState.contains(.visible))
    }
}
