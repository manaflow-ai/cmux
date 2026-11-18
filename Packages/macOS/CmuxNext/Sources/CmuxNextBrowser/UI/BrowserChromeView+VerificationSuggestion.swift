import AppKit
import CmuxNextDesign

/// Shows a verification code offer as the suggestion under the page's code field
/// (``VerificationSuggestionPanel``, a native popup window) instead of the prompt bar, when the
/// page shows a field to anchor it to; otherwise the offer stays in the prompt bar (a link offer
/// always does). When the popup host closes it (a click outside the page, the window moving, the
/// app going inactive), the offer goes back to the prompt bar, still open.
///
/// The field's place comes from ``BrowserTab/verificationFieldAnchor()`` (geometry only, run in an
/// isolated world). The suggestion follows the field when the person scrolls or types, measured
/// again on those events, never on a timer. Keys come from the person's own key presses (an AppKit
/// event monitor, while the suggestion shows and this tab has the keyboard): Down Arrow selects the
/// row, Return then fills, Escape declines. Automation input (CDP, `cmux browser`) is no AppKit
/// event, and an agent-driven tab never gets an offer.
@MainActor
final class VerificationSuggestionController {
    private weak var chrome: BrowserChromeView?
    /// The suggestion window on screen.
    private(set) var card: VerificationSuggestionPanel?
    /// Its popup host: placement, motion and the dismiss rules.
    private var popup: NativePopupHost?
    /// The prompt being measured, or measured with no field (it then stays in the prompt bar).
    private var measuring: ObjectIdentifier?
    private var unanchored: ObjectIdentifier?
    /// The key and scroll monitor while a suggestion shows. It removes itself at its next event when
    /// this controller is gone, so no deinit has to reach main-actor state.
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
        if let card, card.prompt === prompt, popup?.isShown == true { return true }
        if unanchored == key { removeCard(); return false }
        removeCard()
        if measuring == key { return true }
        measuring = key
        Task { [weak self] in
            let anchor = await self?.chrome?.tab.verificationFieldAnchor()
            guard let self, self.measuring == key, !prompt.isResolved else { return }
            self.measuring = nil
            if let anchor, self.showCard(prompt, offer: offer, anchor: anchor) { return }
            self.unanchored = key
            self.chrome?.renderPrompt()
        }
        return true
    }

    /// False when the window cannot show it (hidden, no screen).
    private func showCard(_ prompt: BrowserPrompt, offer: VerificationOffer, anchor: VerificationFieldAnchor) -> Bool {
        guard let chrome, let window = chrome.window, let field = screenRect(of: anchor) else { return false }
        let card = VerificationSuggestionPanel(prompt: prompt, offer: offer)
        card.anchor = anchor
        card.onAccept = { [weak prompt] in prompt?.respond(.accept) }
        let popup = card.makeHost()
        // A click on the page (into the field) leaves it open; anywhere else closes it to the bar.
        popup.keepsOpen = { [weak chrome] event in
            guard let page = chrome?.contentContainer, let pageWindow = page.window, let eventWindow = event.window else { return false }
            let point = eventWindow.convertPoint(toScreen: event.locationInWindow)
            return pageWindow.convertToScreen(page.convert(page.bounds, to: nil)).contains(point)
        }
        let key = ObjectIdentifier(prompt)
        popup.onDismiss = { [weak self] in
            guard let self, self.card === card else { return }
            self.removeCard()
            self.unanchored = key
            self.chrome?.renderPrompt()
        }
        guard popup.show(size: card.cardSize, anchor: field, in: window, preferred: .below) != nil else { return false }
        self.card = card
        self.popup = popup
        startMonitoring()
        return true
    }

    /// The field's rect on the screen.
    private func screenRect(of anchor: VerificationFieldAnchor) -> CGRect? {
        guard let page = chrome?.contentContainer, let window = page.window else { return nil }
        let field = anchor.rect(in: page.bounds.size)
        let local = page.isFlipped ? field : CGRect(x: field.minX, y: page.bounds.height - field.maxY,
                                                    width: field.width, height: field.height)
        return window.convertToScreen(page.convert(local, to: nil))
    }

    private func removeCard() {
        stopMonitoring()
        let popup = self.popup
        card = nil
        self.popup = nil
        popup?.hide()
    }

    /// The field moved (a scroll, typing, a resize): measure again and follow it; gone, the card leaves
    /// for the prompt bar.
    private func remeasure() {
        guard let card else { return }
        let prompt = card.prompt
        if remeasuring { remeasureAgain = true; return }
        remeasuring = true
        Task { [weak self] in
            let anchor = await self?.chrome?.tab.verificationFieldAnchor()
            guard let self else { return }
            self.remeasuring = false
            guard let current = self.card, current === card, !prompt.isResolved else { return }
            if let anchor, let window = self.chrome?.window, let field = self.screenRect(of: anchor) {
                current.anchor = anchor
                self.popup?.show(size: current.cardSize, anchor: field, in: window, preferred: .below)
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
        guard let card, popup?.isShown == true, let chrome, let window = chrome.window,
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
            card.prompt.respond(.cancel)
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

    /// The suggestion window on screen (tests, diagnostics).
    var verificationSuggestionCard: VerificationSuggestionPanel? { verificationSuggestionsIfMade?.card }
}
