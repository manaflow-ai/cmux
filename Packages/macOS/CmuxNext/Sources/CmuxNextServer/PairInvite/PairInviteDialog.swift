public import AppKit
import CmuxNextDesign
import CmuxNextWakeups

/// The Pair Another Machine card: the one cmux dialog card on its glass, top center over the cmux window it was
/// opened from, native from its first frame (Lawrence 2026-11-17: "most dialogs should have 0 react involved"). It
/// draws ``PairInviteModel/step(now:)``: the code large with its QR and countdown, the `cmux pair` line and the
/// install line with Copy; once a machine used the code, Add Server's facts, four words, Name and the Chief option
/// with Confirm. It stays while the person copies the line into another machine's terminal; Cancel, Done or Escape
/// closes it.
///
/// SECURITY: Confirm and Try Again are person-only buttons: only the person's own click on one pairs a machine
/// (``CmuxFloatingDialogPanel/personOnlyClick``), never Return, a script or an MCP call.
@MainActor
public final class PairInviteDialog {
    public let model: PairInviteModel
    /// The card's panel (tests).
    let panel = CmuxFloatingDialogPanel(identifier: "cmux.pairInvite")
    /// Whether an event is the person's own input (the app's HID check); with none set, none is.
    public var isPersonEvent: @MainActor (NSEvent) -> Bool = { _ in false } {
        didSet { panel.personOnlyClick?.isPersonEvent = isPersonEvent }
    }
    private var isOpen = false
    /// The Copy just pressed: its button reads Copied for a moment.
    private var copied: PairInviteModel.CopyTarget?
    private let copiedTimer = DemandTimer(owner: "pairInvite.copied")
    private let expiryTimer = DemandTimer(owner: "pairInvite.expiry")
    var now: () -> Date = Date.init

    public init(model: PairInviteModel) {
        self.model = model
        let click = CmuxDialogPersonClick(activationDelay: { NSEvent.doubleClickInterval })
        panel.personOnlyClick = click
        panel.onPersonPress = { [weak self] id in self?.personPressed(id) }
        panel.takesKeyboardOnShow = true
        panel.onHide = { [weak self] in self?.hidden() }
        model.onChange = { [weak self] in self?.draw() }
    }

    public var isShown: Bool { isOpen && panel.isVisible }

    /// Opens the card over `window` with the keys and mints a new invite; a card still showing a live one keeps it.
    public func open(over window: NSWindow?) {
        let again = isOpen
        isOpen = true
        panel.anchor = { [weak window] in window }
        model.opened(again: again)
        draw()
    }

    /// Takes the card away (the menu bar item went, the app stops serving).
    public func close() {
        panel.hide()
    }

    private func hidden() {
        guard isOpen else { return }
        isOpen = false
        copied = nil
        copiedTimer.cancel()
        expiryTimer.cancel()
        model.closed()
    }

    func draw() {
        guard isOpen else { return }
        let step = model.step(now: now())
        let values = panel.dialogView?.dialog.values ?? [:]
        let spec = PairInviteCard.spec(step, approver: model.approver, qr: model.qr, copied: copied, values: values)
        if case let .showing(invite) = step {
            let left = invite.expiresAt.timeIntervalSince(now())
            // The card turns to Expired at the expiry even if the socket says nothing.
            expiryTimer.schedule(after: .milliseconds(Int(max(left, 0) * 1000) + 50)) { @MainActor [weak self] in self?.draw() }
        } else {
            expiryTimer.cancel()
        }
        guard panel.dialogView?.spec != spec || !panel.isVisible else { return }
        panel.show(spec) { [weak self] id in self?.pressed(id) }
        panel.personOnlyClick?.shown()
    }

    /// A press by click or key. Confirm and Try Again are not answered here: only ``personPressed(_:)`` takes them.
    private func pressed(_ id: String) {
        switch id {
        case PairInviteCard.ID.cancel, PairInviteCard.ID.done: panel.hide()
        case PairInviteCard.ID.newCode: model.newCode()
        case PairInviteCard.ID.copyCode: copy(.code)
        case PairInviteCard.ID.copyLine: copy(.line)
        case PairInviteCard.ID.copyInstallLine: copy(.installLine)
        default: break
        }
    }

    /// SECURITY: the person's own click on Confirm or Try Again (the panel checked the click).
    private func personPressed(_ id: String) {
        guard id == PairInviteCard.ID.confirm || id == PairInviteCard.ID.retry else { return }
        let values = panel.dialogView?.dialog.values ?? [:]
        model.confirm(name: values[PairInviteCard.ID.name]?.text, runChief: values[PairInviteCard.ID.runChief]?.bool)
    }

    private func copy(_ target: PairInviteModel.CopyTarget) {
        guard model.copy(target) else { return }
        copied = target
        draw()
        copiedTimer.schedule(after: .seconds(2)) { @MainActor [weak self] in
            self?.copied = nil
            self?.draw()
        }
    }
}

/// The card's spec for each step (``PairInviteStep``).
enum PairInviteCard {
    enum ID {
        static let cancel = "cancel", done = "done", newCode = "newCode", confirm = "confirm", retry = "retry"
        static let copyCode = "copyCode", copyLine = "copyLine", copyInstallLine = "copyInstallLine"
        static let name = "name", runChief = "runChief"
    }

    static func spec(_ step: PairInviteStep, approver: ServerModel, qr: (String) -> Data?, copied: PairInviteModel.CopyTarget?,
                     values: [String: CmuxDialogValue] = [:]) -> CmuxDialogSpec {
        let cancel = CmuxDialogButton(id: ID.cancel, title: PairInviteStrings.cancel, role: .cancel)
        let newCode = CmuxDialogButton(id: ID.newCode, title: PairInviteStrings.newCode, role: .default)
        let title = PairInviteStrings.title
        func card(_ title: String, lines: [String] = [], fields: [CmuxDialogField] = [], buttons: [CmuxDialogButton],
                  error: String? = nil) -> CmuxDialogSpec {
            CmuxDialogSpec(usesTransientMaterial: true, title: title, lines: lines, fields: fields, buttons: buttons,
                           identifier: "cmux.pairInvite.card", error: error)
        }
        switch step {
        case .minting:
            return card(title, fields: [.progress(PairInviteStrings.minting)], buttons: [cancel])
        case let .showing(invite):
            let copyTitle = { (target: PairInviteModel.CopyTarget, title: String) in copied == target ? PairInviteStrings.copied : title }
            let code = CmuxDialogPairingCode(
                code: invite.displayCode, image: qr(invite.qrPayload), imageLabel: PairInviteStrings.scan, expiresAt: invite.expiresAt,
                expiresFormat: PairInviteStrings.expiresIn, notes: [PairInviteStrings.once, PairInviteStrings.scan],
                copyID: ID.copyCode, copyTitle: copyTitle(.code, PairInviteStrings.copyCode))
            return card(title, lines: [PairInviteStrings.help], fields: [
                .copyLine(id: ID.copyLine, label: nil, text: invite.line, button: copyTitle(.line, PairInviteStrings.copyLine)),
                .pairingCode(code),
                .copyLine(id: ID.copyInstallLine, label: PairInviteStrings.installHelp, text: invite.installLine,
                          button: copyTitle(.installLine, PairInviteStrings.copyInstallLine)),
                .progress(PairInviteStrings.waiting),
            ], buttons: [cancel])
        case .lookingUp:
            return card(PairInviteStrings.arrived, fields: [.progress(PairInviteStrings.lookingUp)], buttons: [cancel])
        case let .review(_, found), let .approving(_, found), let .approveFailed(_, found, _):
            var fields = review(found, approver: approver, values: values)
            var error: String?
            var answer = CmuxDialogButton(id: ID.confirm, title: PairInviteStrings.confirm, role: .default, personOnly: true,
                                          isEnabled: approver.canApprove)
            switch step {
            case .approving:
                fields.append(.progress(PairInviteStrings.adding))
                answer.isEnabled = false
            case let .approveFailed(_, _, reject):
                error = reject
                answer = CmuxDialogButton(id: ID.retry, title: PairInviteStrings.retry, role: .default, personOnly: true,
                                          isEnabled: approver.canApprove)
            default: break
            }
            return card(PairInviteStrings.arrived, lines: [facts(found)], fields: fields, buttons: [cancel, answer], error: error)
        case let .paired(name):
            return card(PairInviteStrings.paired(name), lines: [PairInviteStrings.pairedDetail],
                        buttons: [CmuxDialogButton(id: ID.done, title: PairInviteStrings.done, role: .default)])
        case .voided:
            return card(title, buttons: [cancel, newCode], error: PairInviteStrings.voided)
        case .expired:
            return card(title, lines: [PairInviteStrings.expired], buttons: [cancel, newCode])
        case .lost:
            return card(title, lines: [PairInviteStrings.lost], buttons: [cancel, newCode])
        case .signedOut:
            return card(title, lines: [PairInviteStrings.signedOut], buttons: [cancel])
        case let .failed(text):
            return card(title, buttons: [cancel, newCode], error: text)
        }
    }

    /// The arrived machine's words to compare, its Name and the Chief option; what the person typed survives a redraw.
    private static func review(_ found: PairingCandidate, approver: ServerModel, values: [String: CmuxDialogValue]) -> [CmuxDialogField] {
        [
            .code(label: PairInviteStrings.wordsQuestion, text: words(found.words)),
            .note(PairInviteStrings.wordsWarning, danger: false),
            .text(id: ID.name, label: PairInviteStrings.name, initial: values[ID.name]?.text ?? found.name, placeholder: found.name, secure: false),
            .check(id: ID.runChief, title: PairInviteStrings.runChief, on: values[ID.runChief]?.bool ?? approver.approval.runChief),
            .note(PairInviteStrings.confirmNote, danger: false),
        ]
    }

    /// `build-01 · macOS 15.2 · 0.9.1 · Germany`.
    static func facts(_ found: PairingCandidate) -> String {
        let region = found.region.flatMap { Locale.current.localizedString(forRegionCode: $0) ?? $0 }
        return ([found.name, found.os, found.version, region ?? ""]).filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The words numbered, two to a line: `1 apple   2 river`.
    static func words(_ words: [String]) -> String {
        let numbered = words.enumerated().map { "\($0.offset + 1) \($0.element)" }
        let width = numbered.map(\.count).max() ?? 0
        return stride(from: 0, to: numbered.count, by: 2).map { start in
            numbered[start..<min(start + 2, numbered.count)].enumerated()
                .map { $0.offset == 0 && start + 1 < numbered.count ? $0.element.padding(toLength: width + 3, withPad: " ", startingAt: 0) : $0.element }
                .joined()
        }.joined(separator: "\n")
    }
}
