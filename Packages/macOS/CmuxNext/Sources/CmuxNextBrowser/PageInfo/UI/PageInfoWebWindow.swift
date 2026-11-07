import AppKit
import CmuxNextDesign

/// One Page Info window (certificate viewer, site settings, on-device site data): titled,
/// closable, kind `.pageInfo` (the one surface background), its content a React page
/// (``BrowserChromeWebContent``) at a fixed width. The page reports its content height; the
/// window takes it (up to ``maxContentHeight``, past which the page scrolls) and opens only after
/// the first report, so it never shows an empty frame or grows after it appeared.
final class PageInfoWebWindow: NSWindow {
    /// Past this the page scrolls inside the window.
    static let maxContentHeight: CGFloat = 640

    let content: any BrowserChromeWebContent
    private let width: CGFloat
    /// The page's commands (`{type, ...}`).
    var onCommand: ((PageInfoWindowCommand) -> Void)?
    /// The page reported its first height: the owner places and shows the window.
    var onReady: (() -> Void)?
    /// The window closed (Done, Escape, the close button); the owner drops it.
    var onClose: (() -> Void)?
    private(set) var isReady = false

    init(content: any BrowserChromeWebContent, title: String, width: CGFloat, activeLook: ActiveLookScope?) {
        self.content = content
        self.width = width
        let size = CGSize(width: width, height: Self.maxContentHeight / 2)
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable], backing: .buffered, defer: true)
        self.title = title
        isReleasedWhenClosed = false
        animationBehavior = Motion.overlays.animatesMovement ? .utilityWindow : .none
        let view = content.view
        view.translatesAutoresizingMaskIntoConstraints = true
        view.frame = NSRect(origin: .zero, size: size)
        install(kind: .pageInfo, content: view, scope: themeScope, activeLook: activeLook)
        content.onMessage = { [weak self] kind, params in self?.received(kind, params) }
    }

    /// Sends the page its next state.
    func push(_ state: [String: Any]) {
        content.push(state)
    }

    private func received(_ kind: String, _ params: [String: Any]) {
        switch kind {
        case "command":
            if let command = PageInfoWindowCommand(wire: params) { onCommand?(command) }
        case "size":
            guard let height = (params["height"] as? NSNumber)?.doubleValue, height > 0 else { return }
            fit(contentHeight: ceil(height))
        default:
            break
        }
    }

    /// Takes the page's height at the fixed width, keeping the top edge where it is.
    private func fit(contentHeight: CGFloat) {
        let visible = (screen ?? NSScreen.main)?.visibleFrame.height ?? Self.maxContentHeight
        let size = CGSize(width: width, height: min(contentHeight, Self.maxContentHeight, visible * 0.8))
        if contentRect(forFrameRect: frame).size != size {
            var next = frameRect(forContentRect: NSRect(origin: .zero, size: size))
            next.origin = NSPoint(x: frame.minX, y: frame.maxY - next.height)
            setFrame(next, display: isVisible)
        }
        guard !isReady else { return }
        isReady = true
        onReady?()
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        super.makeKeyAndOrderFront(sender)
        content.focus()
    }

    /// Escape closes (the page sends `close` for its own Escape).
    override func cancelOperation(_ sender: Any?) { close() }

    override func close() {
        super.close()
        content.onMessage = nil
        content.close()
        onClose?()
        onClose = nil
    }
}
