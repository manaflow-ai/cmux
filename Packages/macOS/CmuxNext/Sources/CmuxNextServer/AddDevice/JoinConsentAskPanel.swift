public import AppKit
public import CmuxNextDesign

/// The one-time sheet of the join consent gate: the first request acpmux refused with
/// `consent_required` asks the person at this Mac once. The cmux dialog card in the floating dialog
/// panel (``CmuxFloatingDialogPanel``), like Mac Screen's approval prompt: over every app and full
/// screen, never taking the keyboard or the frontmost app. Only a press on its buttons answers.
///
/// SECURITY: it is left out of every capture cmux makes (screen sharing, `cmux rd serve`, the recorders
/// read `CaptureExcludedWindows`), and Computer Use refuses it (`sharingType = .none`). Since macOS 15.4
/// another app's capture may still show it, so the ask never relies on being unseen: only the person's
/// own click answers Allow.
@MainActor
public final class JoinConsentAskPanel: CmuxFloatingDialogPanel {
    /// Weak: the model's `present` owns this panel.
    weak var model: JoinConsentModel?
    let content: JoinConsentAskView
    /// SECURITY: Allow answers only the person's own click on it (``CmuxDialogPersonClick``).
    let personClick = CmuxDialogPersonClick()
    /// Whether an event is the person's own input (the app's strict source check); with none set, none is.
    public var isPersonEvent: @MainActor (NSEvent) -> Bool {
        get { personClick.isPersonEvent }
        set { personClick.isPersonEvent = newValue }
    }
    /// The event the app is handling now (tests set it).
    var eventInHand: @MainActor () -> NSEvent? {
        get { personClick.eventInHand }
        set { personClick.eventInHand = newValue }
    }

    public init(model: JoinConsentModel) {
        self.model = model
        content = JoinConsentAskView(model: model)
        super.init(identifier: "cmux.joinConsentAsk")
        sharingType = .none
    }

    /// The sheet's own events: the person's click on Allow is read from them (``CmuxDialogPersonClick``).
    override public func sendEvent(_ event: NSEvent) {
        dispatch(event) { super.sendEvent(event) }
    }

    /// SECURITY: Allow answers here, from the person's click itself, never from the button's action: no
    /// Accessibility press, programmatic click or key reaches a grant, inside a dispatch or out of one.
    func dispatch(_ event: NSEvent, _ body: () -> Void) {
        if dispatching == 0 { actionInDispatch = false }
        dispatching += 1
        let taken = personClick.dispatch(event, allow: { [content] in content.allow }, in: windowNumber, body)
        dispatching -= 1
        guard taken else {
            // A click that ended on Allow but is not the person's own, or a key that pressed Allow, grants nothing,
            // and the sheet says why (never between the halves of a click, which a rebuild would break).
            if let up = refusedClickOnAllow(event) {
                model?.allowRefused(why: isPersonEvent(up) ? "a click that began elsewhere, or too soon after the sheet showed"
                                                            : "a click that is not the HID system's own input (posted by a process or a remote driver)")
            } else if dispatching == 0, actionInDispatch, event.type == .keyDown {
                model?.allowRefused(why: "a key press on Allow")
            }
            return
        }
        // task-owner: one answer per click; the sheet hides at once and the write ends on its own
        Task { [weak model] in await model?.answer(allow: true) }
    }

    /// Dispatches in progress: Allow's action inside one is the click's (decided by ``dispatch(_:_:)``).
    private var dispatching = 0
    /// Allow's action ran inside the dispatch now in progress.
    private var actionInDispatch = false

    /// The mouse-up of `event`'s click when it ended inside the enabled Allow (the click
    /// ``CmuxDialogPersonClick`` did not take); nil for any other event.
    private func refusedClickOnAllow(_ event: NSEvent) -> NSEvent? {
        let up = event.type == .leftMouseDown ? eventInHand() : event
        guard let up, up.type == .leftMouseUp, up.windowNumber == windowNumber, let allow = content.allow, allow.isEnabled else { return nil }
        return allow.bounds.contains(allow.convert(up.locationInWindow, from: nil)) ? up : nil
    }

    /// Allow's action outside any click of this sheet (an Accessibility press, a program's click): it grants
    /// nothing, and the sheet says why. Inside a click, the click decides.
    func allowActionPressed() {
        guard dispatching == 0 else { return actionInDispatch = true }
        // task-owner: shows the reason after the action returns, so the rebuild never removes a button mid-action
        Task { [weak model] in model?.allowRefused(why: "a press of Allow that is not a click (Accessibility or a program)") }
    }

    /// SECURITY: whether `up` ends the person's own click on `button`, taken once (``CmuxDialogPersonClick``).
    func takePersonClick(on button: NSView, up: NSEvent) -> Bool {
        personClick.takePersonClick(on: button, up: up, in: windowNumber)
    }

    /// Shows or hides the sheet (``JoinConsentModel/present``): the cmux dialog card at the top right of the screen.
    public func setShown(_ shown: Bool) {
        guard shown, model?.ask != nil else { return hide() }
        content.rebuild()
        present(content)
    }
}

/// The sheet's content: the cmux dialog card with who asked for what, the question, a note, Settings…, Deny
/// (Escape) and Allow. Allow is person-only: it shows no key and no key presses it. Settings… opens Settings >
/// Devices at the switch the sheet asks about and answers nothing, so any press may take it.
@MainActor
public final class JoinConsentAskView: CmuxDialogHostView {
    /// Weak: the model's `present` owns the panel that owns this view.
    weak var model: JoinConsentModel?
    /// The Allow button now shown (``JoinConsentAskPanel/dispatch(_:_:)`` reads the person's click on it).
    var allow: NSControl? { card?.buttonView("allow") }

    public init(model: JoinConsentModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: 432, height: 160))
        setAccessibilityIdentifier("cmux.joinConsentAsk.content")
        rebuild()
    }

    func rebuild() {
        guard let model, let ask = model.ask else { return }
        let spec = CmuxDialogSpec(
            title: JoinConsentStrings.askTitle(ask),
            lines: [JoinConsentStrings.askQuestion(ask.surface), JoinConsentStrings.askNote],
            // Settings… only with Settings > Experiments > Themed Floating Prompts on (off by default, Leo's UI hold).
            buttons: (DesignSettings.shared.themedPrompts ? [CmuxDialogButton(id: "settings", title: JoinConsentStrings.settings)] : []) + [
                CmuxDialogButton(id: "deny", title: JoinConsentStrings.decline(ask.surface), role: .cancel),
                CmuxDialogButton(id: "allow", title: JoinConsentStrings.allow, role: .default, personOnly: true),
            ],
            identifier: "cmux.joinConsentAsk.card", error: model.askError)
        let card = draw(spec) { [weak self] id in
            // SECURITY: Allow's action answers nothing (the panel reads the person's click); outside a click the
            // sheet says why (``JoinConsentAskPanel/allowActionPressed()``). Deny takes any press.
            if id == "deny" { self?.denyPressed() }
            // Settings… only shows the page: the sheet stays up and nothing is written.
            if id == "settings" { self?.model?.showSettings() }
            if id == "allow" { (self?.window as? JoinConsentAskPanel)?.allowActionPressed() }
        }
        card.buttonView("allow")?.setAccessibilityIdentifier("cmux.joinConsentAsk.allow")
        card.buttonView("deny")?.setAccessibilityIdentifier("cmux.joinConsentAsk.deny")
        card.buttonView("settings")?.setAccessibilityIdentifier("cmux.joinConsentAsk.settings")
        // Both stay disabled while a write is in flight: no press lands over a grant still landing.
        card.setButtonsEnabled(model.writing != true)
    }

    // task-owner: one answer per press; the sheet hides at once and the write ends on its own
    private func denyPressed() { Task { [weak model] in await model?.answer(allow: false) } }
}
