public import AppKit
public import CmuxHomeCore
import CmuxNextDesign
public import CmuxNextHomeModel

/// "New Chief…": a name for another Chief and the engine it runs on (Claude, Codex or
/// UniiChat, ``ChiefBackend``); the Chief gets its own conversation. The host's `onCreate`
/// makes it where the engine needs it (``ChiefBackend/createsOnThisMac``): Claude's on the cloud
/// `chief.create` unless the person picks "Make it on this Mac" (``onCreateOnThisMac``).
public final class HomeNewChiefSheet: HomeSheetController, NSTextFieldDelegate {
    public var onCreate: (String, ChiefBackend) async -> HomeComposeOutcome = { _, _ in .offline }
    /// With this set, a cloud engine's Chief can instead run on a Cloud machine of its own ("On its own Cloud
    /// machine"): the host gets the name and this sheet's start key, the same on every Create, so a retry finishes
    /// the first start.
    public var onCreateOnMachine: ((String, String) async -> HomeComposeOutcome)? {
        didSet { showHint() }
    }
    let ownMachine = NSButton(checkboxWithTitle: HomeConversationStrings.chiefOwnMachine, target: nil, action: nil)
    /// This sheet's one machine start (``onCreateOnMachine``).
    let machineKey = UUID().uuidString.lowercased()
    /// With this set, a cloud engine's Chief (Claude) can instead be made on this Mac's Chief owner
    /// ("Make it on this Mac", off by default): the host gets the name and the engine.
    public var onCreateOnThisMac: ((String, ChiefBackend) async -> HomeComposeOutcome)? {
        didSet { showHint() }
    }
    let thisMac = NSButton(checkboxWithTitle: HomeConversationStrings.chiefThisMac, target: nil, action: nil)
    let name = HomeSheetController.field(placeholder: HomeConversationStrings.chiefName, identifier: "cmux.home.chief.name")
    let backend = ThemedPopUpButton(frame: .zero, pullsDown: false)
    /// The chosen engine's one-line note (``ChiefBackend/hint``); hidden when it has none.
    let backendHint = ThemedLabel(wrappingLabelWithString: "")
    static let maxLength = 100

    public init() {
        super.init(title: HomeConversationStrings.chiefTitle, primary: HomeConversationStrings.chiefCreate)
    }

    override func addContent(to stack: NSStackView) {
        let body = ThemedLabel(wrappingLabelWithString: HomeConversationStrings.chiefBody)
        body.font = Typography.body
        body.preferredMaxLayoutWidth = 420 - 2 * Metrics.space6
        stack.addArrangedSubview(body)
        name.delegate = self
        stack.addArrangedSubview(Self.boxed(name))
        let caption = ThemedLabel(labelWithString: HomeConversationStrings.chiefBackend)
        caption.font = Typography.caption
        caption.ink = .secondary
        stack.addArrangedSubview(caption)
        for choice in ChiefBackend.official {
            backend.addItem(withTitle: choice.title)
            backend.lastItem?.representedObject = choice.id
        }
        backend.selectItem(at: 0)
        backend.target = self
        backend.action = #selector(backendChanged(_:))
        backend.setAccessibilityLabel(HomeConversationStrings.chiefBackend)
        backend.setAccessibilityIdentifier("cmux.home.chief.backend")
        stack.addArrangedSubview(backend)
        backendHint.font = Typography.caption
        backendHint.ink = .secondary
        backendHint.preferredMaxLayoutWidth = 420 - 2 * Metrics.space6
        backendHint.setAccessibilityIdentifier("cmux.home.chief.backendHint")
        stack.addArrangedSubview(backendHint)
        ownMachine.setAccessibilityIdentifier("cmux.home.chief.ownMachine")
        stack.addArrangedSubview(ownMachine)
        ownMachine.target = self
        ownMachine.action = #selector(placeChanged(_:))
        thisMac.state = .off
        thisMac.setAccessibilityIdentifier("cmux.home.chief.thisMac")
        stack.addArrangedSubview(thisMac)
        thisMac.target = self
        thisMac.action = #selector(placeChanged(_:))
        showHint()
    }

    override var initialResponder: NSView? { name }

    public override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(name)
    }

    var trimmed: String { name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    override var canSubmit: Bool { !trimmed.isEmpty && trimmed.count <= Self.maxLength }

    /// The engine the popup has chosen (Claude until another is picked).
    var chosenBackend: ChiefBackend {
        (backend.selectedItem?.representedObject as? String).flatMap(ChiefBackend.init(id:)) ?? .claude
    }

    override func submit() {
        let chosen = trimmed
        let engine = chosenBackend
        if let onMachine = onCreateOnMachine, !ownMachine.isHidden, ownMachine.state == .on {
            let key = machineKey
            run { await onMachine(chosen, key) }
            return
        }
        if let onThisMac = onCreateOnThisMac, !thisMac.isHidden, thisMac.state == .on {
            run { await onThisMac(chosen, engine) }
            return
        }
        let create = onCreate
        run { await create(chosen, engine) }
    }

    @objc private func backendChanged(_ sender: NSPopUpButton) { showHint() }

    /// "On its own Cloud machine" and "Make it on this Mac" name two different places, so checking one
    /// unchecks the other; neither checked is the default cloud `chief.create`.
    @objc private func placeChanged(_ sender: NSButton) {
        guard sender.state == .on else { return }
        (sender === ownMachine ? thisMac : ownMachine).state = .off
    }

    private func showHint() {
        let hint = chosenBackend.hint
        backendHint.stringValue = hint ?? ""
        backendHint.isHidden = hint == nil
        ownMachine.isHidden = onCreateOnMachine == nil || chosenBackend.createsOnThisMac
        thisMac.isHidden = onCreateOnThisMac == nil || chosenBackend.createsOnThisMac
    }

    public func controlTextDidChange(_ notification: Notification) { refreshPrimary() }
}
