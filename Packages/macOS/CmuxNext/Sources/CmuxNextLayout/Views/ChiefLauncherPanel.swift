public import AppKit
public import CmuxNextDesign

/// The floating Chief's own window (red: not built yet, an ordinary titled panel nothing shows).
@MainActor
public final class ChiefLauncherPanel: NSPanel {
    /// The defaults key of the saved frames, one per screen.
    public static let framesKey = "chiefLauncher.frames"
    /// Esc, a click outside, Cmd-W: the owner hides the Chief.
    public var onDismiss: (@MainActor () -> Void)?

    /// - Parameter frames: Where the panel was left on each screen.
    public init(frames: FloatingChatFrames) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 440, height: 620), styleMask: [.titled], backing: .buffered, defer: true)
        isReleasedWhenClosed = false
    }

    /// Where the panel opens on a screen whose visible frame is `visible`.
    public static func placement(saved: CGRect?, in visible: CGRect) -> CGRect { .zero }
}
