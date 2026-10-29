import AppKit
import CmuxNextDesign

/// A Command scroll over a web page goes to the page first (`layout.pagesHandleCommandScroll`).
extension LayoutRootView {
    /// A Command scroll from a page window, held until its page answers.
    struct PageProbe {
        struct Held {
            var event: NSEvent
            var locationInWindow: NSPoint
            /// Whether this event decided its gesture's owner when it came.
            var decides: Bool
        }

        /// The page's own window, where the held events go when the page keeps them.
        let window: NSWindow
        var held: [Held]
        let generation: UInt64
        /// A wheel notch, not a trackpad gesture.
        let isWheel: Bool
    }

    /// A page window's last wheel answer and until when it holds (event time).
    struct WheelPageAnswer {
        let window: ObjectIdentifier
        let pageKeeps: Bool
        let until: TimeInterval
    }
}
