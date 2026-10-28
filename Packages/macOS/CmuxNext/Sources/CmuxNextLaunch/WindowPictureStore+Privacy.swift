public import AppKit

/// The privacy fills of a window's picture: what must never reach the disk shows the
/// theme background instead. A terminal holding Secure Input is filled even when the quit took its frame; a browser
/// page that is withheld (an incognito profile, Secure Input, protected media, a window hidden from screen capture)
/// is filled even when a picture of it exists, and so is one the quit took no picture of. A whole window that is
/// incognito or hidden from capture leaves no picture at all (``WindowPictureStore/Eligibility``). The rules are
/// checked again here, after the page captures awaited: a page that took Secure Input while they ran is filled.
extension WindowPictureStore.Pane {
    /// What the quit knows of a pane's content; ``Content/init(_:)`` applies the privacy rules to it.
    public enum Source {
        /// A terminal: its surface, the frame the quit took (nil: none), and whether it holds Secure Input now.
        case terminal(surface: NSView, frame: CGImage?, holdsSecureInput: Bool)
        /// An agent page's picture, drawn from the content area's top-left corner at `size` points.
        case agentPage(CGImage, size: CGSize)
        /// A browser page: its content view, the picture the quit took of it at `pageFrame` (points from the content
        /// area's top-left corner; nil when none was taken), and whether it is withheld now.
        case browserPage(NSView, picture: CGImage?, pageFrame: CGRect, withheld: Bool)
        /// A cmux page or the empty state: AppKit draws it.
        case cmuxPage
    }
}

extension WindowPictureStore.Pane.Content {
    /// What `source` shows in the window's picture, with the privacy fills applied.
    public init(_ source: WindowPictureStore.Pane.Source) {
        switch source {
        case .terminal(let surface, let frame, let holdsSecureInput):
            if holdsSecureInput {
                self = .fill(surface)
            } else if let frame {
                self = .picture(frame, of: surface)
            } else {
                self = .drawn
            }
        case .agentPage(let image, let size):
            self = .placed(image, at: CGRect(origin: .zero, size: size))
        case .browserPage(let view, let picture, let pageFrame, let withheld):
            if let picture, !withheld {
                self = .placed(picture, at: pageFrame)
            } else {
                self = .fill(view)
            }
        case .cmuxPage:
            self = .drawn
        }
    }
}
