import AppKit
import CmuxBrowser
import CmuxCEF
import SwiftUI

/// Places a non-WebKit page's content view in a browser pane.
///
/// The page's content view fills the pane. For a Chromium page it is the
/// placeholder its Chromium window tracks, so the page follows the pane's
/// frame and visibility.
///
/// A Chromium page draws in a child window that takes the keyboard when it
/// becomes key. The container follows the rule cmux Next uses
/// (`ChromiumKeyWindowFacts`): a click into the page chooses it, and the pane
/// asks for panel focus as a click into a WebKit page does; a page window
/// that became key without a click while cmux wants the keyboard elsewhere
/// (the address bar, another pane) gives it back to this window.
struct BrowserEnginePageHost: NSViewRepresentable {
    let page: any BrowserPage
    let isVisible: Bool
    let shouldFocus: Bool
    /// Called with the page's content view once it is in the container.
    var onAttach: (NSView) -> Void = { _ in }
    /// A click into the page chose it.
    var onPageClicked: () -> Void = {}
    /// The page went on or off screen (crash recovery restores a page that
    /// crashed while hidden once it shows).
    var onVisibilityChange: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> BrowserEnginePageContainerView {
        let container = BrowserEnginePageContainerView(frame: .zero)
        container.wantsLayer = true
        attach(page.contentView, to: container)
        return container
    }

    func updateNSView(_ container: BrowserEnginePageContainerView, context: Context) {
        if page.contentView.superview !== container {
            attach(page.contentView, to: container)
        }
        let wantsFocus = shouldFocus && isVisible
        let wantedFocus = container.wantsPageFocus
        container.wantsPageFocus = wantsFocus
        container.onPageClicked = onPageClicked
        // The first attach runs before the container is in a window; attach
        // again once it is, so overlays sync with the placed page.
        container.onMovedToWindow = { [onAttach, page] in onAttach(page.contentView) }
        page.setContentVisible(isVisible)
        if container.reportedVisible != isVisible {
            container.reportedVisible = isVisible
            onVisibilityChange(isVisible)
        }
        if wantsFocus {
            page.setFocused(true)
        } else if wantedFocus {
            // Withdraw the page's focus request, so showing or re-creating
            // it later (a tab switch, Memory Saver) doesn't take the keys
            // from where cmux moved them.
            page.setFocused(false)
        }
    }

    static func dismantleNSView(_ container: BrowserEnginePageContainerView, coordinator: ()) {
        container.onPageClicked = nil
        container.onMovedToWindow = nil
        for subview in container.subviews {
            subview.removeFromSuperview()
        }
    }

    private func attach(_ content: NSView, to container: NSView) {
        content.removeFromSuperview()
        content.frame = container.bounds
        content.autoresizingMask = [.width, .height]
        container.addSubview(content)
        onAttach(content)
    }
}

/// The pane's container for a non-WebKit page; watches its Chromium page
/// window take the keyboard.
final class BrowserEnginePageContainerView: NSView {
    /// cmux wants this page to have the keyboard (the pane is focused and the
    /// address bar is not). When that ends while this pane's page window has
    /// the keyboard (Cmd-L, a move to another pane), this window takes it
    /// back so the address bar or the next pane gets the keys.
    var wantsPageFocus = false {
        didSet {
            guard oldValue, !wantsPageFocus else { return }
            // Set inside a SwiftUI update: move key status after it.
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.wantsPageFocus else { return }
                self.reclaimKeyFromPageWindowIfOverPane()
            }
        }
    }
    var onPageClicked: (() -> Void)?
    /// The visibility last reported through `onVisibilityChange`.
    var reportedVisible: Bool?
    var onMovedToWindow: (() -> Void)?
    private var keyObserver: (any NSObjectProtocol)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
        guard window != nil else { return }
        onMovedToWindow?()
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            let keyWindow = note.object as? NSWindow
            MainActor.assumeIsolated { self?.pageWindowBecameKey(keyWindow) }
        }
    }

    deinit {
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated {
            if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        }
    }

    private func pageWindowBecameKey(_ keyWindow: NSWindow?) {
        guard let keyWindow, let window, keyWindow !== window, keyWindow.isChromiumPageWindow,
              !isHiddenOrHasHiddenAncestor else { return }
        let parent: ChromiumKeyWindowFacts.Parent
        if keyWindow.parent == nil {
            parent = .none
        } else {
            parent = keyWindow.chromiumActingWindow(fallback: nil) === window ? .thisWindow : .other
        }
        let paneRect = window.convertToScreen(convert(bounds, to: nil))
        let center = CGPoint(x: keyWindow.frame.midX, y: keyWindow.frame.midY)
        // Only a press delivered to the page window itself chooses it (not a
        // click elsewhere during which Chromium activated the page).
        let event = NSApp.currentEvent
        let facts = ChromiumKeyWindowFacts(
            parent: parent,
            isChromiumPage: true,
            clicked: Self.isMouseDown(event) && event?.window === keyWindow,
            overPane: paneRect.contains(center),
            thisWindowIsActive: NSApp.mainWindow === window
        )
        switch facts.decision {
        case .chosenPage where !wantsPageFocus:
            onPageClicked?()
        case .unchosenPage where facts.overPane && !wantsPageFocus:
            // Chromium took the keys for this pane's page on its own. Not
            // while a gated focus change runs: that change made this page
            // window key, and taking the key back would focus the page again
            // through cmux's becomeKey handler, recursing until the stack ends.
            ChromiumFocusReentrancyGate.shared.run { window.makeKey() }
        case .chosenPage, .unchosenPage, .devTools, .reapply, .ignore:
            break
        }
    }

    private func reclaimKeyFromPageWindowIfOverPane() {
        // A hidden tab's container shares the pane rect with the tab shown
        // in its place; it must not take the keys from that tab's page.
        guard let window, !isHiddenOrHasHiddenAncestor, let keyWindow = NSApp.keyWindow, keyWindow !== window,
              keyWindow.isChromiumPageWindow,
              keyWindow.chromiumActingWindow(fallback: NSApp.mainWindow) === window else { return }
        let paneRect = window.convertToScreen(convert(bounds, to: nil))
        guard paneRect.contains(CGPoint(x: keyWindow.frame.midX, y: keyWindow.frame.midY)) else { return }
        ChromiumFocusReentrancyGate.shared.run { window.makeKey() }
    }

    private static func isMouseDown(_ event: NSEvent?) -> Bool {
        switch event?.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: true
        default: false
        }
    }
}
