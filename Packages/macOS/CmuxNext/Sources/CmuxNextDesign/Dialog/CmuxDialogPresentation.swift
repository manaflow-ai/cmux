public import AppKit
public import CmuxNextDesignTokens

/// One shown dialog, as its host and its drawing see it: the spec, every field's current value, and
/// the keyboard (`CmuxDialogKeys`). It draws nothing. The drawing is ``CmuxDialogView`` (a
/// ``CmuxDialogRendering``): the card sends the person's edits and presses here, and gets the values
/// automation sets and the focus moves keys ask.
/// `CmuxDialogCenter` owns the answer.
@MainActor
public final class CmuxDialogPresentation {
    public let id: Int
    public let spec: CmuxDialogSpec
    /// The window's active-look scope the card keeps the key look with while it fades out.
    public let activeLook: ActiveLookScope?
    /// Every field's current value by field id.
    public private(set) var values: [String: CmuxDialogValue]
    /// Called once per press with the button id; the center ends the dialog.
    var onPress: ((String) -> Void)?
    /// The drawing of this dialog, while one shows it.
    public weak var renderer: (any CmuxDialogRendering)?
    /// The view the host shows (the card's region), while it is on screen.
    public internal(set) weak var view: NSView?
    /// The card's rect in ``view``'s coordinates, as it last laid out; nil before.
    public var cardRect: CGRect? {
        didSet {
            guard cardRect != nil else { return }
            resumeCardWaiters()
            onCardRect?()
        }
    }
    /// The host follows the card (an app-scope dialog's region grows to hold it).
    var onCardRect: (() -> Void)?
    /// Who waits for the card's first rect (`debug.dialog_strip`): resumed when it arrives.
    var cardWaiters: [CheckedContinuation<Void, Never>] = []

    func resumeCardWaiters() {
        let waiters = cardWaiters
        cardWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    init(id: Int, spec: CmuxDialogSpec, activeLook: ActiveLookScope?) {
        self.id = id
        self.spec = spec
        self.activeLook = activeLook
        values = Self.initialValues(spec)
    }

    /// The window the dialog shows in (its overlay panel), while it shows.
    public var window: NSWindow? { view?.window }
    /// The host presented ``view`` in its overlay (it may wait in its source window before, while its
    /// card draws); false again when the overlay hides it.
    public private(set) var isPresented = false
    private var presentedWaiters: [() -> Void] = []

    /// Runs `body` once ``view`` is presented in its overlay, now when it is.
    public func whenPresented(_ body: @escaping () -> Void) {
        if isPresented { body() } else { presentedWaiters.append(body) }
    }

    func notePresented(_ presented: Bool) {
        isPresented = presented
        guard presented else { return }
        let waiters = presentedWaiters
        presentedWaiters = []
        waiters.forEach { $0() }
    }

    // MARK: From the drawing

    /// The person changed fields: values for ids the spec has, of the kind the field takes.
    public func edited(_ edits: [String: CmuxDialogValue]) {
        for (id, value) in edits where accepts(value, for: id) { values[id] = value }
    }

    /// The person pressed button `id` with these field values; false when the dialog has no such button.
    @discardableResult
    public func press(_ id: String, values edits: [String: CmuxDialogValue] = [:]) -> Bool {
        guard spec.buttons.contains(where: { $0.id == id }) else { return false }
        edited(edits)
        onPress?(id)
        return true
    }

    // MARK: Automation and missed keys

    /// Sets one field (automation); false when the dialog has no such field or the value does not fit it.
    @discardableResult
    public func setValue(_ value: CmuxDialogValue, for id: String) -> Bool {
        guard accepts(value, for: id) else { return false }
        values[id] = value
        renderer?.dialogValuesChanged(self)
        return true
    }

    /// Runs `key` against this dialog; true when the dialog used it.
    @discardableResult
    public func handle(_ key: CmuxDialogKeys.Key, modifiers: CmuxDialogKeys.Modifiers) -> Bool {
        guard let action = CmuxDialogKeys.action(for: key, modifiers: modifiers, in: spec) else { return false }
        switch action {
        case .press(let id): press(id)
        case .focusNext: renderer?.dialogMoveFocus(self, backward: false)
        case .focusPrevious: renderer?.dialogMoveFocus(self, backward: true)
        }
        return true
    }

    /// The key that presses `button`, as the card shows it; nil when none does or the layout draws no key glyphs.
    public func hint(for button: CmuxDialogButton) -> CmuxDialogKeyHint? {
        spec.layout == .safeDefault ? nil : CmuxDialogKeys.hint(for: button, in: spec)
    }

    static func key(_ event: NSEvent) -> CmuxDialogKeys.Key? {
        switch event.keyCode {
        case 36, 76: return .return
        case 53: return .escape
        case 48: return .tab
        default: return event.charactersIgnoringModifiers?.first.map { .character($0) }
        }
    }

    static func modifiers(_ event: NSEvent) -> CmuxDialogKeys.Modifiers {
        var modifiers: CmuxDialogKeys.Modifiers = []
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        return modifiers
    }

    // MARK: Values

    private func accepts(_ value: CmuxDialogValue, for id: String) -> Bool {
        for field in spec.fields where field.id == id {
            switch (field, value) {
            case (.text, .text): return true
            case (.choice(_, _, let options, _), .text(let picked)): return options.contains { $0.value == picked && $0.isEnabled }
            case (.check, .bool): return true
            default: return false
            }
        }
        return false
    }

    /// The spec's initial values: a choice starts on its selected option when that one is enabled, else
    /// on the first enabled one (a disabled option is never the selection).
    static func initialValues(_ spec: CmuxDialogSpec) -> [String: CmuxDialogValue] {
        var values: [String: CmuxDialogValue] = [:]
        for field in spec.fields {
            switch field {
            case .text(let id, _, let initial, _, _): values[id] = .text(initial)
            case .choice(let id, _, let options, let selected):
                let enabled = options.filter(\.isEnabled)
                values[id] = .text(selected.flatMap { s in enabled.first { $0.value == s }?.value } ?? enabled.first?.value ?? "")
            case .check(let id, _, let on): values[id] = .bool(on)
            case .preview: break
            }
        }
        return values
    }
}

/// What draws a shown dialog (``CmuxDialogView``): told when automation changes a value and when a
/// key moves the focus, so the card shows the same state the center reports.
@MainActor
public protocol CmuxDialogRendering: AnyObject {
    func dialogValuesChanged(_ dialog: CmuxDialogPresentation)
    func dialogMoveFocus(_ dialog: CmuxDialogPresentation, backward: Bool)
}
