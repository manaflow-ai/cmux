import AppKit
import CmuxNextDesign

/// Shows a verification code offer as the suggestion under the page's code field
/// (``VerificationSuggestionView``) instead of the prompt bar, when the page shows a field to
/// anchor it to; otherwise the offer stays in the prompt bar (a link offer always does).
///
/// The field's place comes from ``BrowserTab/verificationFieldAnchor()`` (geometry only, run in an
/// isolated world). The card follows the field when the person scrolls or types, measured again
/// on those events, never on a timer. Keys come from the person's own key presses (an AppKit
/// event monitor, while the card shows and this tab has the keyboard): Down Arrow selects the
/// card, Return then fills, Escape declines. Automation input (CDP, `cmux browser`) is no AppKit
/// event, and an agent-driven tab never gets an offer.
@MainActor
final class VerificationSuggestionController {
    private weak var chrome: BrowserChromeView?
    private(set) var card: VerificationSuggestionView?
    /// The prompt being measured, or measured with no field (it then stays in the prompt bar).
    private var measuring: ObjectIdentifier?
    private var unanchored: ObjectIdentifier?
    /// The key and scroll monitor while a card shows. It removes itself at its next event when this
    /// controller is gone, so no deinit has to reach main-actor state.
    private var monitor: MonitorToken?
    /// A measure runs; another event while it runs measures once more after it.
    private var remeasuring = false
    private var remeasureAgain = false

    init(chrome: BrowserChromeView) {
        self.chrome = chrome
    }

    /// Shows `prompt` as the suggestion when it is a code offer with a field to anchor to. True when
    /// the suggestion owns it (shown, or still being measured): the prompt bar then stays hidden.
    func render(_ prompt: BrowserPrompt?) -> Bool {
        guard let prompt, case .verificationOffer(let offer) = prompt.kind, offer.code != nil, !prompt.isResolved else {
            removeCard()
            measuring = nil
            return false
        }
        let key = ObjectIdentifier(prompt)
        if let card, card.prompt === prompt, !card.isDismissing { return true }
        if unanchored == key { removeCard(); return false }
        removeCard()
        if measuring == key { return true }
        measuring = key
        Task { [weak self] in
            let anchor = await self?.chrome?.tab.verificationFieldAnchor()
            guard let self, self.measuring == key, !prompt.isResolved else { return }
            self.measuring = nil
            if let anchor {
                self.showCard(prompt, offer: offer, anchor: anchor)
            } else {
                self.unanchored = key
                self.chrome?.renderPrompt()
            }
        }
        return true
    }

    private func showCard(_ prompt: BrowserPrompt, offer: VerificationOffer, anchor: VerificationFieldAnchor) {
        guard let chrome else { return }
        let card = VerificationSuggestionView()
        card.show(prompt, offer: offer)
        card.anchor = anchor
        card.onAccept = { [weak prompt] in prompt?.respond(.accept) }
        card.onDecline = { [weak prompt] in prompt?.respond(.cancel) }
        chrome.pageOverlays.add(card, placement: .anchored(topLeft: topLeft(for: card, anchor: anchor)))
        card.alphaValue = 0
        self.card = card
        chrome.syncPageOverlays()
        Motion.overlays.animate(.fadeIn, in: card) { card.animator().alphaValue = 1 }
        startMonitoring()
    }

    /// Under the field, or above it when the page has no room below.
    private func topLeft(for card: VerificationSuggestionView, anchor: VerificationFieldAnchor) -> CGPoint {
        guard let page = chrome?.contentContainer else { return .zero }
        let field = anchor.rect(in: page.bounds.size)
        let gap = Metrics.space1
        let height = card.fittingSize.height
        let below = field.maxY + gap
        let y = below + height <= page.bounds.height - BrowserMetrics.overlayInset ? below : max(BrowserMetrics.overlayInset, field.minY - gap - height)
        return CGPoint(x: field.minX, y: y)
    }

    private func removeCard() {
        stopMonitoring()
        guard let card, let chrome else { self.card = nil; return }
        self.card = nil
        card.isDismissing = true
        chrome.pageOverlays.release(card)
        Motion.overlays.animate(.fadeOut, in: card, { card.animator().alphaValue = 0 }, completion: { [weak chrome] in
            chrome?.pageOverlays.remove(card)
        })
    }

    /// The field moved (a scroll, typing, a resize): measure again and follow it; gone, the card leaves
    /// for the prompt bar.
    private func remeasure() {
        guard let card, let prompt = card.prompt else { return }
        if remeasuring { remeasureAgain = true; return }
        remeasuring = true
        Task { [weak self] in
            let anchor = await self?.chrome?.tab.verificationFieldAnchor()
            guard let self else { return }
            self.remeasuring = false
            guard let current = self.card, current === card, !prompt.isResolved else { return }
            if let anchor {
                current.anchor = anchor
                self.chrome?.pageOverlays.move(current, to: self.topLeft(for: current, anchor: anchor))
            } else {
                self.unanchored = ObjectIdentifier(prompt)
                self.chrome?.renderPrompt()
            }
            if self.remeasureAgain {
                self.remeasureAgain = false
                self.remeasure()
            }
        }
    }

    private func startMonitoring() {
        guard monitor == nil else { return }
        let token = MonitorToken()
        token.value = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel]) { [weak self] event in
            guard let self else {
                token.remove()
                return event
            }
            return self.handle(event)
        }
        monitor = token
    }

    private func stopMonitoring() {
        monitor?.remove()
        monitor = nil
    }

    /// The person's own keys and scrolls over this tab's page; anything else passes untouched.
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let card, !card.isDismissing, let chrome, let window = chrome.window,
              event.window === window || event.window?.parent === window else { return event }
        if event.type == .scrollWheel {
            remeasure()
            return event
        }
        guard chrome.boundState?.hasKeyboard ?? true, !chrome.tab.isAgentDriven,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
        switch event.keyCode {
        case 125: // Down Arrow
            guard !card.isSelected else { return nil }
            card.isSelected = true
            return nil
        case 126 where card.isSelected: // Up Arrow
            card.isSelected = false
            return nil
        case 36 where card.isSelected, 76 where card.isSelected: // Return, Enter
            card.onAccept?()
            return nil
        case 53: // Escape
            card.onDecline?()
            return nil
        default:
            card.isSelected = false
            remeasure()
            return event
        }
    }
}

/// An `NSEvent` monitor handle that can remove itself once.
private final class MonitorToken {
    var value: Any?

    func remove() {
        if let value { NSEvent.removeMonitor(value) }
        value = nil
    }
}

extension BrowserChromeView {
    /// The code suggestion of this chrome's tab, made on first use.
    var verificationSuggestions: VerificationSuggestionController {
        if let existing = verificationSuggestionsIfMade { return existing }
        let controller = VerificationSuggestionController(chrome: self)
        verificationSuggestionsIfMade = controller
        return controller
    }

    /// The suggestion card on screen (tests, diagnostics).
    var verificationSuggestionCard: VerificationSuggestionView? { verificationSuggestionsIfMade?.card }
}
