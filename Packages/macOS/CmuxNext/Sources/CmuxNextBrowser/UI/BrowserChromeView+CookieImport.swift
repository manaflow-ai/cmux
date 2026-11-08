public import AppKit
import CmuxNextDesign

/// What the cookie import card says (the host localizes it) and the icons
/// of the browsers it can import from, most used first.
public struct BrowserCookieImportOffer {
    public var icons: [NSImage]
    public var title: String
    public var detail: String
    public var importTitle: String
    public var notNowTitle: String
    /// A quiet third answer (Don't Show Again); nil shows only Not Now and Import.
    public var neverTitle: String?
    /// "Keep in sync", a checkbox under the detail (a browser whose cookies can be kept in sync); nil shows none.
    public var keepInSyncTitle: String?
    /// The checkbox's first state.
    public var keepInSync: Bool
    /// The checkbox's state when the person clicked Import (before `onChoice`).
    public var onKeepInSync: (@MainActor (Bool) -> Void)?

    public init(icons: [NSImage], title: String, detail: String, importTitle: String, notNowTitle: String, neverTitle: String? = nil,
                keepInSyncTitle: String? = nil, keepInSync: Bool = true, onKeepInSync: (@MainActor (Bool) -> Void)? = nil) {
        self.icons = icons
        self.title = title
        self.detail = detail
        self.importTitle = importTitle
        self.notNowTitle = notNowTitle
        self.neverTitle = neverTitle
        self.keepInSyncTitle = keepInSyncTitle
        self.keepInSync = keepInSync
        self.onKeepInSync = onKeepInSync
    }
}

/// The person's answer on the cookie import card.
public enum BrowserCookieImportChoice: Sendable, Equatable {
    case importCookies
    case notNow
    case never
}

// The cookie import card over the bottom of the page
// (BrowserCookieImportCard, a React page in native glass). The host decides when to offer it; the chrome
// keeps at most one and closes it on any answer.
extension BrowserChromeView {
    /// Shows `offer` at the bottom of the page, replacing an offer already
    /// shown. It floats on the window's overlay host (`PageFloatingOverlays`),
    /// so it shows above Chromium pages too.
    /// `aboveToast` lifts it over the window's toast stack (a toast shows now).
    public func showCookieImportOffer(_ offer: BrowserCookieImportOffer, aboveToast: Bool = false,
                                      onChoice: @escaping (BrowserCookieImportChoice) -> Void) {
        if let shown = currentCookieImportCard { remove(shown) }
        let card = BrowserCookieImportCard(offer: offer)
        card.onChoice = { [weak self, weak card] choice in
            if let card { self?.remove(card) }
            onChoice(choice)
        }
        // It shows once its page measured its lines, at their height: never empty, never growing.
        card.onReady = { [weak self, weak card] in
            guard let self, let card, !card.isDismissing else { return }
            pageOverlays.startTakingClicks(card)
            syncPageOverlays()
            Motion.overlays.animate(.fadeIn, in: card) { card.animator().alphaValue = 1 }
        }
        card.onResize = { [weak self] in self?.syncPageOverlays() }
        // Until then it is clear and every click goes to the page under it.
        pageOverlays.add(card, lift: aboveToast ? Self.toastClearance : 0, passesThroughClicks: true)
        card.alphaValue = 0
        syncPageOverlays()
        needsLayout = true
    }

    /// Room the window's toast stack takes at the bottom: one toast and its gaps.
    static var toastClearance: CGFloat { BrowserMetrics.findBarHeight + BrowserMetrics.overlayInset * 2 }

    /// Closes the offer, if one is shown.
    public func hideCookieImportOffer() {
        if let shown = currentCookieImportCard { remove(shown) }
    }

    /// Whether an offer is on screen (tests, diagnostics).
    public var showsCookieImportOffer: Bool { currentCookieImportCard.map { !$0.isHidden && !$0.waitsForFocus } ?? false }

    /// Takes out, at once, the offer this chrome holds hidden for `state` (the tab moved to another pane).
    func takeHeldCookieOffer(for state: BrowserChromeTabState) -> BrowserCookieImportCard? {
        guard let card = currentCookieImportCard, card.heldFor === state else { return nil }
        card.isDismissing = true
        pageOverlays.remove(card)
        card.retire()
        return card
    }

    var currentCookieImportCard: BrowserCookieImportCard? {
        pageOverlays.views.lazy.compactMap { $0 as? BrowserCookieImportCard }.first { !$0.isDismissing }
    }

    private func remove(_ card: BrowserCookieImportCard) {
        guard !card.isDismissing else { return }
        card.isDismissing = true
        pageOverlays.release(card)
        Motion.overlays.animate(.fadeOut, in: card, { card.animator().alphaValue = 0 }, completion: { [weak self] in
            self?.pageOverlays.remove(card)
            card.retire()
        })
    }
}
