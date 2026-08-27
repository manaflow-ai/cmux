import AppKit
import CmuxBrowser
import WebKit

/// Holds a browser presentation root in a persistent, imperceptible rendering window.
@MainActor
final class BrowserOffscreenRenderHost {
    private let webView: WKWebView
    private let presentationView: NSView
    private let previousSuperview: NSView?
    private let previousFrame: NSRect
    private let previousBounds: NSRect
    private let previousAutoresizingMask: NSView.AutoresizingMask
    private let previousTranslatesAutoresizingMaskIntoConstraints: Bool
    private let restoreAnchor: NSView?
    private let restorePosition: NSWindow.OrderingMode
    private let window: BrowserOffscreenRenderPanel
    private let contentView: NSView
    private let mirrorView: BrowserStreamMacMirrorView?
    private var isFinished = false

    init(webView: WKWebView, viewportSize: NSSize) {
        let capturedPresentationView = webView.cmuxBrowserViewportPresentationView
        let capturedPreviousSuperview = capturedPresentationView.superview
        let previousSubviews = capturedPreviousSuperview?.subviews ?? []
        let previousIndex = previousSubviews.firstIndex(of: capturedPresentationView)
        let capturedRestoreAnchor: NSView?
        let capturedRestorePosition: NSWindow.OrderingMode
        if let previousIndex, previousIndex > 0 {
            capturedRestoreAnchor = previousSubviews[previousIndex - 1]
            capturedRestorePosition = .above
        } else if let previousIndex, previousIndex == 0, previousSubviews.count > 1 {
            capturedRestoreAnchor = previousSubviews[1]
            capturedRestorePosition = .below
        } else {
            capturedRestoreAnchor = nil
            capturedRestorePosition = .above
        }

        // While the live web view renders offscreen, the pane would otherwise be
        // blank; a read-only mirror keeps the Mac pane showing what the phone sees.
        let capturedMirrorView = capturedPreviousSuperview != nil
            ? BrowserStreamMacMirrorView(frame: .zero)
            : nil

        let normalizedSize = Self.normalizedViewportSize(viewportSize)
        let frame = Self.renderFrame(for: normalizedSize)
        let renderWindow = BrowserOffscreenRenderPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        renderWindow.isReleasedWhenClosed = false
        renderWindow.identifier = NSUserInterfaceItemIdentifier("cmux.browserVisualAutomationRender")
        renderWindow.hasShadow = false
        renderWindow.isOpaque = false
        renderWindow.backgroundColor = .clear
        renderWindow.alphaValue = 0.01
        renderWindow.ignoresMouseEvents = true
        renderWindow.level = .floating
        renderWindow.hidesOnDeactivate = false
        renderWindow.collectionBehavior = [.transient, .ignoresCycle, .stationary, .canJoinAllSpaces]
        renderWindow.isExcludedFromWindowsMenu = true
        let renderContentView = NSView(frame: NSRect(origin: .zero, size: normalizedSize))
        renderContentView.wantsLayer = true

        self.webView = webView
        presentationView = capturedPresentationView
        previousSuperview = capturedPreviousSuperview
        previousFrame = capturedPresentationView.frame
        previousBounds = capturedPresentationView.bounds
        previousAutoresizingMask = capturedPresentationView.autoresizingMask
        previousTranslatesAutoresizingMaskIntoConstraints =
            capturedPresentationView.translatesAutoresizingMaskIntoConstraints
        restoreAnchor = capturedRestoreAnchor
        restorePosition = capturedRestorePosition
        window = renderWindow
        contentView = renderContentView
        mirrorView = capturedMirrorView

        webView.cmuxBeginBrowserViewportExternalRenderHost()
        capturedPresentationView.removeFromSuperview()
        if let capturedMirrorView, let capturedPreviousSuperview {
            capturedMirrorView.frame = capturedPreviousSuperview.bounds
            capturedMirrorView.autoresizingMask = [.width, .height]
            capturedPreviousSuperview.addSubview(capturedMirrorView)
        }
        renderContentView.addSubview(capturedPresentationView)
        webView.cmuxApplyBrowserViewportLayout(in: renderContentView.bounds)
        renderWindow.contentView = renderContentView
        renderWindow.orderFrontRegardless()
        forceLayout()
    }

    /// Resizes the persistent render window and reapplies the active viewport layout.
    @discardableResult
    func resize(to viewportSize: NSSize) -> Bool {
        guard !isFinished, presentationView.superview === contentView else { return false }
        let normalizedSize = Self.normalizedViewportSize(viewportSize)
        window.setFrame(Self.renderFrame(for: normalizedSize), display: false)
        contentView.frame = NSRect(origin: .zero, size: normalizedSize)
        contentView.bounds = NSRect(origin: .zero, size: normalizedSize)
        webView.cmuxApplyBrowserViewportLayout(in: contentView.bounds)
        forceLayout()
        return true
    }

    /// Feeds the latest streamed frame to the Mac-side mirror shown in the pane.
    func updateMirror(_ image: NSImage) {
        guard !isFinished else { return }
        mirrorView?.updateImage(image)
    }

    /// Restores the captured presentation root to its prior hierarchy and geometry.
    @discardableResult
    func restore() -> Bool {
        finish(restorePresentation: true)
    }

    /// Tears down a host whose web view was replaced and must not be reattached.
    func abandon() {
        _ = finish(restorePresentation: false)
    }

    @discardableResult
    private func finish(restorePresentation: Bool) -> Bool {
        guard !isFinished else { return false }
        isFinished = true

        mirrorView?.removeFromSuperview()

        let policy = BrowserViewportRestorationPolicy(
            temporaryHostIsCurrent: presentationView.superview === contentView,
            hasPreviousHost: previousSuperview != nil,
            hasVisibleWebKitCompanion: previousSuperview?
                .browserPortalHasVisibleWebKitCompanionSubview(for: webView) ?? false
        )
        let shouldRestore = restorePresentation && policy.shouldRestorePreviousHost
        if shouldRestore {
            presentationView.removeFromSuperview()
            if let previousSuperview {
                if let restoreAnchor, restoreAnchor.superview === previousSuperview {
                    previousSuperview.addSubview(
                        presentationView,
                        positioned: restorePosition,
                        relativeTo: restoreAnchor
                    )
                } else {
                    previousSuperview.addSubview(presentationView)
                }
            }

            if policy.shouldPreservePreviousGeometry {
                presentationView.frame = previousFrame
                presentationView.bounds = previousBounds
                presentationView.autoresizingMask = previousAutoresizingMask
                presentationView.translatesAutoresizingMaskIntoConstraints =
                    previousTranslatesAutoresizingMaskIntoConstraints
            } else if let previousSuperview {
                webView.cmuxApplyBrowserViewportLayout(in: previousSuperview.bounds)
            }
        } else if presentationView.superview === contentView {
            presentationView.removeFromSuperview()
        }

        webView.cmuxEndBrowserViewportExternalRenderHost()
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        return shouldRestore
    }

    private func forceLayout() {
        webView.needsLayout = true
        presentationView.needsLayout = true
        contentView.needsLayout = true
        contentView.layoutSubtreeIfNeeded()
        presentationView.layoutSubtreeIfNeeded()
        webView.layoutSubtreeIfNeeded()
        presentationView.displayIfNeeded()
        webView.displayIfNeeded()
    }

    private static func normalizedViewportSize(_ viewportSize: NSSize) -> NSSize {
        let fallback = NSSize(width: 1280, height: 720)
        let width = viewportSize.width.isFinite && viewportSize.width > 1
            ? viewportSize.width
            : fallback.width
        let height = viewportSize.height.isFinite && viewportSize.height > 1
            ? viewportSize.height
            : fallback.height
        return NSSize(
            width: min(max(width, 1), 4096),
            height: min(max(height, 1), 4096)
        )
    }

    private static func renderFrame(for viewportSize: NSSize) -> NSRect {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            return NSRect(origin: .zero, size: viewportSize)
        }

        // WebKit suspends rAF and degrades trusted-event hit testing/delivery when
        // its host window is occluded. Keep a visible on-screen portion at a level
        // ordinary windows cannot cover so the stream's beacon and input stay live.
        let screenFrame = screen.frame
        let minimumVisibleWidth = min(64, viewportSize.width, max(0, screenFrame.width))
        let minimumVisibleHeight = min(64, viewportSize.height, max(0, screenFrame.height))
        let preferredOrigin = NSPoint(
            x: screenFrame.maxX - viewportSize.width,
            y: screenFrame.minY
        )
        let minimumX = screenFrame.minX - viewportSize.width + minimumVisibleWidth
        let maximumX = screenFrame.maxX - minimumVisibleWidth
        let minimumY = screenFrame.minY - viewportSize.height + minimumVisibleHeight
        let maximumY = screenFrame.maxY - minimumVisibleHeight
        let origin = NSPoint(
            x: min(max(preferredOrigin.x, minimumX), maximumX),
            y: min(max(preferredOrigin.y, minimumY), maximumY)
        )
        return NSRect(origin: origin, size: viewportSize)
    }
}

/// Read-only mirror of the streamed frames, shown in the Mac pane while the live
/// web view renders in the offscreen host. Letterboxes the phone-width frame so
/// the pane reflects what the phone shows instead of going blank; click-through
/// because the phone owns interaction. Removed on teardown when the web view
/// returns to the pane.
@MainActor
final class BrowserStreamMacMirrorView: NSView {
    private let imageView = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.animates = false
        imageView.wantsLayer = true
        imageView.frame = bounds
        imageView.autoresizingMask = [.width, .height]
        addSubview(imageView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateImage(_ image: NSImage) {
        imageView.image = image
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
