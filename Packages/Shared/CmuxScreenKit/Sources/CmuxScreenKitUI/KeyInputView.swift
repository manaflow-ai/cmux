#if os(iOS)
import CmuxScreenKit
import UIKit

/// The software keyboard's target: typed text goes to the remote computer.
/// Its accessory bar adds the keys an iPhone keyboard lacks (Esc, Tab,
/// arrows) and sticky Control, Option and Command, which apply to the next key.
final class KeyInputView: UIView, UIKeyInput {
    weak var session: ScreenSession?
    private lazy var bar = KeyBar(owner: self)

    override var canBecomeFirstResponder: Bool { true }
    override var inputAccessoryView: UIView? { bar }

    var hasText: Bool { true }
    var autocorrectionType: UITextAutocorrectionType { get { .no } set {} }
    var autocapitalizationType: UITextAutocapitalizationType { get { .none } set {} }
    var spellCheckingType: UITextSpellCheckingType { get { .no } set {} }
    var smartQuotesType: UITextSmartQuotesType { get { .no } set {} }
    var smartDashesType: UITextSmartDashesType { get { .no } set {} }
    var smartInsertDeleteType: UITextSmartInsertDeleteType { get { .no } set {} }
    var keyboardType: UIKeyboardType { get { .asciiCapable } set {} }

    func insertText(_ text: String) {
        session?.type(text, modifiers: bar.takeModifiers())
    }

    func deleteBackward() {
        session?.tap(.backspace, modifiers: bar.takeModifiers())
    }

    func tap(_ key: VNCKeysym) {
        session?.tap(key, modifiers: bar.takeModifiers())
    }

    /// Hardware keys by HID usage (layout-independent, like a VNC viewer on
    /// a Mac). Returns false when no press carried a key.
    @discardableResult
    func forward(_ presses: Set<UIPress>, down: Bool) -> Bool {
        var handled = false
        for press in presses {
            guard let key = press.key, let keysym = VNCKeysym(hidUsage: UInt32(key.keyCode.rawValue)) else { continue }
            session?.key(keysym, down: down)
            handled = true
        }
        return handled
    }

    // While this view is first responder, hardware keys arrive here; handle
    // them as physical keys and keep them from also arriving as text.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !forward(presses, down: true) { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !forward(presses, down: false) { super.pressesEnded(presses, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !forward(presses, down: false) { super.pressesCancelled(presses, with: event) }
    }
}

/// The accessory row above the software keyboard.
final class KeyBar: UIInputView {
    private weak var owner: KeyInputView?
    private var latched: [VNCKeysym: UIButton] = [:]
    private let modifierOrder: [VNCKeysym] = [.control, .option, .command]

    init(owner: KeyInputView) {
        self.owner = owner
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 48), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 48),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
        let keys: [(String, VNCKeysym?, VNCKeysym?)] = [
            ("esc", .escape, nil), ("tab", .tab, nil),
            ("ctrl", nil, .control), ("opt", nil, .option), ("⌘", nil, .command),
            ("←", .left, nil), ("↑", .up, nil), ("↓", .down, nil), ("→", .right, nil),
            ("home", .home, nil), ("end", .end, nil), ("pgup", .pageUp, nil), ("pgdn", .pageDown, nil),
            ("del", .deleteForward, nil), ("F1", .function(1), nil), ("F5", .function(5), nil),
        ]
        for (title, key, modifier) in keys {
            let button = UIButton(configuration: .gray())
            button.configuration?.title = title
            button.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
            button.accessibilityLabel = modifier.map { _ in "\(title) modifier" } ?? title
            if let modifier {
                button.addAction(UIAction { [weak self, weak button] _ in
                    guard let self, let button else { return }
                    toggle(modifier, button)
                }, for: .touchUpInside)
            } else if let key {
                button.addAction(UIAction { [weak self] _ in self?.owner?.tap(key) }, for: .touchUpInside)
            }
            stack.addArrangedSubview(button)
        }
        let done = UIButton(configuration: .filled())
        done.configuration?.image = UIImage(systemName: "keyboard.chevron.compact.down")
        done.accessibilityLabel = "Hide keyboard"
        done.addAction(UIAction { [weak self] _ in self?.owner?.resignFirstResponder() }, for: .touchUpInside)
        stack.addArrangedSubview(done)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func toggle(_ modifier: VNCKeysym, _ button: UIButton) {
        let active = latched.removeValue(forKey: modifier) == nil
        if active { latched[modifier] = button }
        style(button, active: active)
    }

    /// The latched modifiers, in a fixed order; they release after one key.
    func takeModifiers() -> [VNCKeysym] {
        let modifiers = modifierOrder.filter { latched[$0] != nil }
        for button in latched.values { style(button, active: false) }
        latched.removeAll()
        return modifiers
    }

    private func style(_ button: UIButton, active: Bool) {
        let title = button.configuration?.title
        var configuration: UIButton.Configuration = active ? .tinted() : .gray()
        configuration.title = title
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
        button.configuration = configuration
        button.isSelected = active
    }
}
#endif
