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
    /// The number of the newest state pushed; a size report for an older one is dropped.
    private var revision = 0

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
        revision += 1
        var state = state
        state["revision"] = revision
        content.push(state)
    }

    private func received(_ kind: String, _ params: [String: Any]) {
        switch kind {
        case "command":
            if let command = PageInfoWindowCommand(wire: params) { onCommand?(command) }
        case "size":
            guard let height = (params["height"] as? NSNumber)?.doubleValue, height > 0,
                  (params["revision"] as? NSNumber)?.intValue == revision else { return }
            fit(contentHeight: ceil(height))
        default:
            break
        }
    }

    /// Takes the page's height at the fixed width, keeping the top edge where it is.
    private func fit(contentHeight: CGFloat) {
        let visibleFrame = (screen ?? NSScreen.main)?.visibleFrame
        let visible = visibleFrame?.height ?? Self.maxContentHeight
        let size = CGSize(width: width, height: min(contentHeight, Self.maxContentHeight, visible * 0.8))
        if contentRect(forFrameRect: frame).size != size {
            let next = frameRect(forContentRect: NSRect(origin: .zero, size: size))
            setFrame(Self.resized(frame, to: next.size, within: visibleFrame), display: isVisible)
        }
        guard !isReady else { return }
        isReady = true
        onReady?()
    }

    /// `frame` at `size` with its top edge kept, moved up as far as it must to stay on `visible`
    /// (a Site data window centered while it loaded grows downward when its rows arrive).
    nonisolated static func resized(_ frame: NSRect, to size: CGSize, within visible: NSRect?) -> NSRect {
        var next = NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height)
        guard let visible else { return next }
        if next.minY < visible.minY { next.origin.y = min(visible.minY, visible.maxY - next.height) }
        if next.maxY > visible.maxY { next.origin.y = visible.maxY - next.height }
        return next
    }

    /// Each time the window becomes key, the page takes the keys.
    override func becomeKey() {
        super.becomeKey()
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
