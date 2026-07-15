import AppKit
import CEFKit

/// Owns one transient CEF extension popup through asynchronous browser teardown.
@MainActor
final class CEFExtensionPopoverController: NSObject,
    NSPopoverDelegate,
    @preconcurrency CEFBrowserDelegate
{
    private var popover: NSPopover?
    private var containerView: CEFBrowserContainerView?
    private var browser: CEFBrowser?
    private var isCreatingBrowser = false
    private var isClosing = false
    private var waitingForPopoverClose = false

    /// Keeps the controller, browser, and host alive until CEF confirms destruction.
    private var closingRetain: CEFExtensionPopoverController?

    func show(
        action: CEFExtensionAction,
        profile: CEFProfile?,
        relativeTo anchorView: NSView
    ) {
        guard !isClosing else { return }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 400, height: 580)
        popover.delegate = self

        let container = CEFBrowserContainerView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 580)
        )
        let contentController = NSViewController()
        contentController.view = container
        popover.contentViewController = contentController

        self.popover = popover
        containerView = container
        popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)

        isCreatingBrowser = true
        CEFBrowser.create(
            in: container,
            frame: container.bounds,
            url: action.popupURL.absoluteString,
            profile: profile,
            delegate: self
        ) { [weak self] browser in
            guard let self else {
                browser?.close(force: true)
                return
            }
            self.isCreatingBrowser = false
            guard let browser else {
                if self.popover?.isShown == true {
                    self.beginClosing(waitingForPopoverClose: true)
                    self.popover?.performClose(nil)
                } else if !self.isClosing {
                    self.beginClosing()
                }
                self.finishClosingIfPossible()
                return
            }
            self.browser = browser
            if self.isClosing {
                browser.close(force: true)
            }
        }
    }

    func close() {
        guard !isClosing else { return }
        let popoverIsShown = popover?.isShown == true
        beginClosing(waitingForPopoverClose: popoverIsShown)
        if popoverIsShown {
            popover?.performClose(nil)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        _ = notification
        waitingForPopoverClose = false
        beginClosing()
        finishClosingIfPossible()
    }

    func browserDidClose(_ browser: CEFBrowser) {
        guard browser === self.browser else { return }
        self.browser = nil
        finishClosingIfPossible()
    }

    private func beginClosing(waitingForPopoverClose: Bool = false) {
        guard !isClosing else { return }
        isClosing = true
        self.waitingForPopoverClose = waitingForPopoverClose
        closingRetain = self
        if let browser {
            browser.setFocus(false)
            browser.close(force: true)
        } else {
            finishClosingIfPossible()
        }
    }

    private func finishClosingIfPossible() {
        guard isClosing, !waitingForPopoverClose, !isCreatingBrowser, browser == nil else { return }
        popover?.delegate = nil
        popover?.contentViewController = nil
        popover = nil
        containerView = nil
        closingRetain = nil
    }

    func beginClosingForTesting(waitingForPopoverClose: Bool) {
        beginClosing(waitingForPopoverClose: waitingForPopoverClose)
    }

    var isRetainedForClosingForTesting: Bool {
        closingRetain === self
    }

    func completePopoverCloseForTesting() {
        waitingForPopoverClose = false
        finishClosingIfPossible()
    }
}
