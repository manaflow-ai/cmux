public import AppKit
public import CmuxHomeCore
import CmuxNextDesign

/// "New Chief…": a name for another Chief and the engine it runs on: the official engines
/// (``ChiefBackend``) and, once the host hands them (``show(_:)``), every harness this Mac's acpmux
/// lists, the ones not set up here marked. The Chief gets its own conversation. The host's
/// `onCreate` makes it where the engine needs it (``ChiefBackend/createsOnThisMac``).
public final class HomeNewChiefSheet: HomeSheetController, NSTextFieldDelegate {
    public var onCreate: (String, ChiefBackend) async -> HomeComposeOutcome = { _, _ in .offline }
    let name = HomeSheetController.field(placeholder: HomeConversationStrings.chiefName, identifier: "cmux.home.chief.name")
    let backend = ThemedPopUpButton(frame: .zero, pullsDown: false)
    /// The chosen engine's one-line note (``ChiefBackend/hint``); hidden when it has none.
    let backendHint = ThemedLabel(wrappingLabelWithString: "")
    /// The choices the popup lists, by harness id (their state's hint shows when one is chosen).
    private var choices: [String: HomeChiefHarnessChoice] = [:]
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
        fill(HomeChiefHarnessChoice.choices(listed: []))
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
        showHint()
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(name)
    }

    var trimmed: String { name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    override var canSubmit: Bool { !trimmed.isEmpty && trimmed.count <= Self.maxLength }

    /// Lists `choices` (``HomeChiefHarnessChoice/choices(listed:)``), keeping the one chosen.
    public func show(_ choices: [HomeChiefHarnessChoice]) {
        _ = view
        fill(choices)
        showHint()
    }

    private func fill(_ list: [HomeChiefHarnessChoice]) {
        let chosen = backend.selectedItem?.representedObject as? String
        backend.removeAllItems()
        choices = [:]
        for choice in list {
            choices[choice.id] = choice
            backend.addItem(withTitle: choice.itemTitle)
            backend.lastItem?.representedObject = choice.id
        }
        let index = chosen.flatMap { id in backend.itemArray.firstIndex { $0.representedObject as? String == id } } ?? 0
        if backend.numberOfItems > 0 { backend.selectItem(at: index) }
    }

    /// The engine the popup has chosen (Claude until another is picked).
    var chosenBackend: ChiefBackend {
        (backend.selectedItem?.representedObject as? String).map(ChiefBackend.harness) ?? .claude
    }

    override func submit() {
        let chosen = trimmed
        let engine = chosenBackend
        let create = onCreate
        run { await create(chosen, engine) }
    }

    @objc func backendChanged(_ sender: NSPopUpButton) { showHint() }

    private func showHint() {
        let chosen = chosenBackend
        let hint = choices[chosen.id]?.stateHint ?? chosen.hint
        backendHint.stringValue = hint ?? ""
        backendHint.isHidden = hint == nil
    }

    public func controlTextDidChange(_ notification: Notification) { refreshPrimary() }
}
