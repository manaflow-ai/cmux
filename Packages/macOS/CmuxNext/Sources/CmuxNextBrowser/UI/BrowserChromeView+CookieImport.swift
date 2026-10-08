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
    public var neverTitle: String

    public init(icons: [NSImage], title: String, detail: String, importTitle: String, notNowTitle: String, neverTitle: String) {
        self.icons = icons
        self.title = title
        self.detail = detail
        self.importTitle = importTitle
        self.notNowTitle = notNowTitle
        self.neverTitle = neverTitle
    }
}

/// The person's answer on the cookie import card.
public enum BrowserCookieImportChoice: Sendable, Equatable {
    case importCookies
    case notNow
    case never
}

// The cookie import card over the bottom of the page
// (BrowserCookieImportCard). The host decides when to offer it; the chrome
// keeps at most one and closes it on any answer.
extension BrowserChromeView {
    /// Shows `offer` at the bottom of the page, replacing an offer already
    /// shown. Child-window (Chromium) pages draw above the chrome; the card
    /// is one of their occlusion rects, so it shows over them too.
    public func showCookieImportOffer(_ offer: BrowserCookieImportOffer, onChoice: @escaping (BrowserCookieImportChoice) -> Void) {
        if let shown = currentCookieImportCard { remove(shown) }
        let card = BrowserCookieImportCard(offer: offer)
        card.onChoice = { [weak self, weak card] choice in
            if let card { self?.remove(card) }
            onChoice(choice)
        }
        addSubview(card)
        let inset = BrowserMetrics.overlayInset
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: contentContainer.centerXAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: inset),
        ])
        card.alphaValue = 0
        Motion.animate(.fadeIn, in: card) { card.animator().alphaValue = 1 }
        needsLayout = true
    }

    /// Closes the offer, if one is shown.
    public func hideCookieImportOffer() {
        if let shown = currentCookieImportCard { remove(shown) }
    }

    /// Whether an offer is on screen (tests, diagnostics).
    public var showsCookieImportOffer: Bool { currentCookieImportCard != nil }

    var currentCookieImportCard: BrowserCookieImportCard? {
        subviews.lazy.compactMap { $0 as? BrowserCookieImportCard }.first { !$0.isDismissing }
    }

    private func remove(_ card: BrowserCookieImportCard) {
        guard !card.isDismissing else { return }
        card.isDismissing = true
        Motion.animate(.fadeOut, in: card, { card.animator().alphaValue = 0 }, completion: { [weak self] in
            card.removeFromSuperview()
            self?.needsLayout = true
        })
    }

    /// Reports each page that finished loading once (`onPageFinished`).
    func reportFinishedLoad(_ state: BrowserTabState) {
        guard let onPageFinished, case .finished = state.phase, let url = state.url, url != finishedURL else { return }
        finishedURL = url
        onPageFinished(url)
    }
}
