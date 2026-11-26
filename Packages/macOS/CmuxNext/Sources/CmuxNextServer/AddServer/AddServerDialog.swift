public import AppKit
import CmuxNextDesign
import CmuxNextCompat

/// The Add Server card (palette "Add Server…", a pairing link, `cmux server add`): the one cmux dialog card on its
/// glass, top center over the cmux window, native from its first frame (Lawrence 2026-11-17: "most dialogs should
/// have 0 react involved"). It draws ``ServerModel/addServerStep``: the code field, then the found server's facts,
/// four words, Name, Team and the Chief option, then added. Cancel, Deny, Done or Escape closes it.
///
/// SECURITY: Approve and Try Again are person-only buttons: only the person's own click on one adds the found server
/// to their team (``CmuxFloatingDialogPanel/personOnlyClick``), never Return, a script or an MCP call.
@MainActor
public final class AddServerDialog {
    public let model: ServerModel
    /// The card's panel (tests).
    let panel = CmuxFloatingDialogPanel(identifier: "cmux.addServer")
    /// Whether an event is the person's own input (the app's HID check); with none set, none is.
    public var isPersonEvent: @MainActor (NSEvent) -> Bool = { _ in false } {
        didSet { panel.personOnlyClick?.isPersonEvent = isPersonEvent }
    }
    private var isOpen = false
    /// The card's shape last drawn: what it shows apart from what the person types, so a keystroke never redraws it.
    private var shape: CmuxDialogSpec?
    private var watch: Task<Void, Never>?

    /// - Parameter isPersonEvent: Whether an event is the person's own input (the app's HID check).
    public init(model: ServerModel, isPersonEvent: @escaping @MainActor (NSEvent) -> Bool = { _ in false }) {
        self.model = model
        self.isPersonEvent = isPersonEvent
        panel.personOnlyClick = CmuxDialogPersonClick(activationDelay: { NSEvent.doubleClickInterval })
        panel.personOnlyClick?.isPersonEvent = isPersonEvent
        panel.onPersonPress = { [weak self] id in self?.personPressed(id) }
        panel.onHide = { [weak self] in self?.hidden() }
    }

    // Not an isolated deinit (cx-t7hu): the handle is Sendable and cancels from any thread.
    nonisolated deinit {
        watch?.cancel()
    }

    public var isShown: Bool { isOpen && panel.isVisible }

    /// Opens the card over `window`. Opened by hand it takes the keys for the code field; a code that arrived from
    /// outside (a pairing link, a script without the words) shows without them, so the person's typing elsewhere
    /// goes on until they click the card. The model already began (``ServerModel/beginApproval()``).
    public func open(over window: NSWindow?, takeKeys: Bool) {
        if !isOpen { shape = nil }
        isOpen = true
        panel.anchor = { [weak window] in window }
        panel.takesKeyboardOnShow = takeKeys
        startWatch()
        draw()
    }

    /// Takes the card away (the menu bar item went, the app stops serving).
    public func close() {
        panel.hide()
    }

    /// The card closed any way but its Cancel or Deny: the typed code stays, and the found server goes, so a
    /// reopening looks the code up again (``ServerModel/closeApproval()``).
    private func hidden() {
        guard isOpen else { return }
        isOpen = false
        watch?.cancel()
        watch = nil
        model.closeApproval()
    }

    /// One observation of the model while the card is open. Primed now, so a change before the task runs is seen.
    private func startWatch() {
        guard watch == nil else { return }
        let model = model
        let later = ObservationStream.current({ Self.fingerprint(model) }).later
        // task-owner: the open card; cancelled when it hides. Event-driven (Observation).
        watch = Task { [weak self] in
            for await _ in later {
                guard !Task.isCancelled, let self else { return }
                self.draw()
            }
        }
    }

    private static func fingerprint(_ model: ServerModel) -> String {
        "\(model.addServerStep)|\(model.canApprove)|\(model.approval)"
    }

    func draw() {
        guard isOpen else { return }
        let shape = AddServerCard.spec(model, values: [:], typed: false)
        if shape != self.shape || !panel.isVisible {
            self.shape = shape
            let values = panel.dialogView?.dialog.values ?? [:]
            let card = panel.show(AddServerCard.spec(model, values: values, typed: true)) { [weak self] id in self?.pressed(id) }
            card.dialog.onEdit = { [weak self] values in self?.edited(values) }
            panel.personOnlyClick?.shown()
        }
        // Approve dims while the draft cannot go (no name, no team), with no redraw.
        if case .approving = model.addServerStep { return }
        panel.dialogView?.buttonView(AddServerCard.ID.approve)?.isEnabled = model.canApprove
    }

    /// The person typed or picked: the draft follows the fields.
    private func edited(_ values: [String: CmuxDialogValue]) {
        typealias ID = AddServerCard.ID
        if let code = values[ID.code]?.text { model.setApprovalCode(code) }
        if let name = values[ID.name]?.text { model.approval.name = name }
        if let team = values[ID.team]?.text, model.candidate?.teams.contains(where: { $0.id == team }) == true { model.approval.team = team }
        if let on = values[ID.runChief]?.bool { model.approval.runChief = on }
    }

    /// A press by click or key. Approve and Try Again are not answered here: only ``personPressed(_:)`` takes them.
    private func pressed(_ id: String) {
        switch id {
        case AddServerCard.ID.cancel:
            model.dismissApproval()
            panel.hide()
        case AddServerCard.ID.done:
            model.dismissApproval()
            panel.hide()
        default: break
        }
    }

    /// SECURITY: the person's own click on Approve or Try Again (the panel checked the click).
    private func personPressed(_ id: String) {
        guard id == AddServerCard.ID.approve else { return }
        switch model.addServerStep {
        case .review, .approveFailed: guard model.canApprove else { return }
        default: return
        }
        model.approval.name = model.approval.name.trimmingCharacters(in: .whitespacesAndNewlines)
        model.approve()
    }
}

/// The Add Server card's spec for each step (``AddServerStep``).
enum AddServerCard {
    enum ID {
        static let code = "code", name = "name", team = "team", runChief = "runChief"
        static let cancel = "cancel", approve = "approve", done = "done"
    }

    /// The card for the model's step. `typed`: the fields start from what the person typed (`values`), else from
    /// nothing: the card's shape, compared to skip a redraw.
    @MainActor
    static func spec(_ model: ServerModel, values: [String: CmuxDialogValue], typed: Bool) -> CmuxDialogSpec {
        func card(_ title: String, lines: [String], fields: [CmuxDialogField], buttons: [CmuxDialogButton], error: String? = nil) -> CmuxDialogSpec {
            CmuxDialogSpec(usesTransientMaterial: true, title: title, lines: lines, fields: fields, buttons: buttons,
                           identifier: "cmux.addServer.card", error: error)
        }
        let step = model.addServerStep
        if case let .added(name) = step {
            return card(AddServerStrings.added(name), lines: [AddServerStrings.addedDetail], fields: [],
                        buttons: [CmuxDialogButton(id: ID.done, title: AddServerStrings.done, role: .default)])
        }
        // The shape (typed false) leaves out every field's value: typing, a team pick or the Chief option never redraws.
        let value = { (id: String, initial: CmuxDialogValue) in typed ? values[id] ?? initial : nil }
        // What the person typed while it is the draft's code; a code set from outside (a pairing link) replaces it.
        func code(_ field: String?) -> String {
            guard let field else { return "" }
            return PairingCode.editing(field) == model.approval.code ? field : model.approval.code
        }
        var fields: [CmuxDialogField] = [
            .text(id: ID.code, label: nil, initial: code(value(ID.code, .text(model.approval.code))?.text), placeholder: "XXXX-XXXX",
                  secure: false),
        ]
        var error: String?
        // Enabled once a server is found; the card dims it while the draft cannot go (``AddServerDialog/draw()``).
        var approve = CmuxDialogButton(id: ID.approve, title: AddServerStrings.approve, role: .default, personOnly: true,
                                       isEnabled: AddServerStrings.showsServer(step))
        switch step {
        case .enterCode: fields.append(.note(AddServerStrings.codeHint, danger: false))
        case .lookingUp: fields.append(.progress(AddServerStrings.lookingUp))
        case let .codeRefused(reject):
            fields.append(.note(reject, danger: true))
            fields.append(.note(AddServerStrings.expiryHint, danger: false))
        case let .review(found), let .approving(found), let .approveFailed(found, _):
            fields += review(found, name: value(ID.name, .text(model.approval.name))?.text ?? "",
                             team: value(ID.team, .text(model.approval.team ?? ""))?.text,
                             runChief: value(ID.runChief, .bool(model.approval.runChief))?.bool ?? false)
            if case .approving = step {
                fields.append(.progress(AddServerStrings.adding))
                approve.title = AddServerStrings.adding
                approve.isEnabled = false
            }
            if case let .approveFailed(_, reject) = step {
                error = reject
                // retry-prompt-ok: SECURITY: approving grants a server access to this account; only the person's own click sends it again
                approve.title = AddServerStrings.retry
            }
        case .added: break
        }
        let found = AddServerStrings.showsServer(step)
        let cancel = CmuxDialogButton(id: ID.cancel, title: found ? AddServerStrings.deny : AddServerStrings.cancel, role: .cancel)
        return card(AddServerStrings.title, lines: [AddServerStrings.subtitle], fields: fields, buttons: [cancel, approve], error: error)
    }

    /// The found server: its facts and words to compare, Name, Team (when it offers more than one) and the Chief option.
    private static func review(_ found: PairingCandidate, name: String, team: String?, runChief: Bool) -> [CmuxDialogField] {
        var fields: [CmuxDialogField] = [
            .note(PairInviteCard.facts(found), danger: false),
            .code(label: AddServerStrings.wordsQuestion, text: PairInviteCard.words(found.words)),
            .note(AddServerStrings.wordsWarning, danger: false),
            .text(id: ID.name, label: AddServerStrings.name, initial: name, placeholder: found.name, secure: false),
        ]
        // One team needs no choice.
        if found.teams.count > 1 {
            fields.append(.choice(id: ID.team, label: AddServerStrings.team,
                                  options: found.teams.map { CmuxDialogOption(label: $0.name, value: $0.id) }, selected: team))
        }
        fields.append(.check(id: ID.runChief, title: AddServerStrings.runChief, on: runChief))
        return fields
    }
}
