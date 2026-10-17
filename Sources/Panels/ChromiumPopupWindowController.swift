import AppKit
import CmuxBrowser
import CmuxCEFBrowser
import CmuxFoundation
import ObjectiveC

/// Shows a sized popup a Chromium page opened (`window.open` with window
/// features: OAuth sign-in, payment, "Sign in with…") in the same popup
/// window a WebKit panel uses: a titled `BrowserPopupPanel` sized from the
/// request and clamped to the opener's screen (`browserPopupContentRect`),
/// with the page's origin under the title bar so a sign-in page cannot hide
/// where it comes from. The page keeps `window.opener` (the engine created it
/// in the opener's Chromium context).
///
/// Lifecycle mirrors `BrowserPopupWindowController`: the controller retains
/// itself through its panel and goes away when the panel closes; closing the
/// panel closes the page, and the page's `window.close()` closes the panel.
/// An extension's popup window (`chrome.windows.create({type: "popup"})`)
/// opens here too: Chromium's own window for it attaches over the page, so
/// `chrome.windows.update` moves or resizes the panel and
/// `chrome.windows.remove` (the page closing) closes it.
///
/// References: design review on #21050 (popups must open the way WebKit opens
/// them, spec §0.1); Classic `BrowserPopupWindowController.swift`,
/// `BrowserPopupPanel.swift`; cmux Next `Popups/BrowserPopupPanel.swift`.
@MainActor
final class ChromiumPopupWindowController: NSObject, NSWindowDelegate {
    private static var associatedObjectKey: UInt8 = 0
    private static let defaultSize = NSSize(width: 800, height: 600)
    private static let minimumSize = NSSize(width: 200, height: 150)

    private let page: any BrowserPage
    private let panel: BrowserPopupPanel
    private let originLabel = NSTextField(labelWithString: "")
    private var eventsTask: Task<Void, Never>?
    private var isClosing = false

    /// Opens `page` in a popup window sized `width` x `height` (points) near `opener`.
    @discardableResult
    static func present(_ page: any BrowserPage, width: Double?, height: Double?, opener: NSWindow?) -> ChromiumPopupWindowController {
        ChromiumPopupWindowController(page: page, width: width, height: height, opener: opener)
    }

    private init(page: any BrowserPage, width: Double?, height: Double?, opener: NSWindow?) {
        self.page = page
        let screen = opener?.screen ?? NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let contentRect = browserPopupContentRect(
            requestedWidth: width.map { CGFloat($0) },
            requestedHeight: height.map { CGFloat($0) },
            requestedX: nil,
            requestedTopY: nil,
            visibleFrame: visibleFrame,
            defaultWidth: Self.defaultSize.width,
            defaultHeight: Self.defaultSize.height,
            minWidth: Self.minimumSize.width,
            minHeight: Self.minimumSize.height
        )
        panel = BrowserPopupPanel(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.identifier = NSUserInterfaceItemIdentifier("cmux.browser-popup")
        panel.level = .normal
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = Self.minimumSize
        panel.title = String(localized: "browser.popup.loadingTitle", defaultValue: "Loading\u{2026}")
        panel.delegate = self

        originLabel.translatesAutoresizingMaskIntoConstraints = false
        originLabel.textColor = .secondaryLabelColor
        originLabel.lineBreakMode = .byTruncatingMiddle
        originLabel.font = GlobalFontMagnification.systemFont(ofSize: 11)
        originLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let container = NSView()
        let content = page.contentView
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(originLabel)
        container.addSubview(content)
        panel.contentView = container
        NSLayoutConstraint.activate([
            originLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            originLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            originLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            content.topAnchor.constraint(equalTo: originLabel.bottomAnchor, constant: 2),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        objc_setAssociatedObject(panel, &Self.associatedObjectKey, self, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        apply(page.state)
        let events = page.events
        eventsTask = Task { @MainActor [weak self] in
            for await event in events {
                guard let self else { return }
                switch event {
                case .stateChanged(let state):
                    self.apply(state)
                // An Escape the page left unhandled closes the popup, as
                // in cmux Next (`BrowserPopupPanels`).
                case .closeRequested, .unhandledEscape:
                    self.panel.close()
                default:
                    break
                }
            }
            // The page closed on its own (chrome.windows.remove of an
            // extension popup window): the panel goes with it.
            guard !Task.isCancelled, let self, !self.isClosing else { return }
            self.panel.close()
        }
        (page as? CEFBrowserPage)?.onPopupWindowBoundsRequest = { [weak self] frame in
            self?.applyRequestedFrame(frame)
        }
        // Opened by the page's own request: it comes forward like a WebKit popup.
        panel.makeKeyAndOrderFront(nil)
        page.setContentVisible(true)
        page.setFocused(true)
    }

    private func apply(_ state: BrowserPageState) {
        if let title = state.title, !title.isEmpty, panel.title != title { panel.title = title }
        let origin = state.url.map { BrowserURLAllowlistBlockedPage.safeDisplayOrigin(for: $0) } ?? ""
        if originLabel.stringValue != origin { originLabel.stringValue = origin }
    }

    /// `frame`: screen points from the primary display's top-left (Chromium's
    /// window coordinates), clamped to the panel's screen like a new popup.
    private func applyRequestedFrame(_ frame: CGRect) {
        guard !isClosing else { return }
        let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? panel.frame
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? visibleFrame.maxY
        let contentRect = browserPopupContentRect(
            requestedWidth: frame.width,
            requestedHeight: frame.height,
            requestedX: frame.minX,
            requestedTopY: frame.minY - (primaryTop - visibleFrame.maxY),
            visibleFrame: visibleFrame,
            defaultWidth: Self.defaultSize.width,
            defaultHeight: Self.defaultSize.height,
            minWidth: Self.minimumSize.width,
            minHeight: Self.minimumSize.height
        )
        panel.setFrame(panel.frameRect(forContentRect: contentRect), display: true)
    }

    func windowWillClose(_ notification: Notification) {
        isClosing = true
        eventsTask?.cancel()
        eventsTask = nil
        page.close()
        objc_setAssociatedObject(panel, &Self.associatedObjectKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}
