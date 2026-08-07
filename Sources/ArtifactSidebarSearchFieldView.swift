import AppKit

/// Native Artifacts search endpoint registered with the owning main window.
@MainActor
final class ArtifactSidebarSearchFieldView: NSTextField {
    private var onValueChanged: ((String) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        isContinuous = true
        target = self
        action = #selector(valueChanged)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerWithKeyboardFocusCoordinatorIfNeeded()
    }

    override func layout() {
        super.layout()
        registerWithKeyboardFocusCoordinatorIfNeeded()
    }

    func update(value: String, placeholder: String, onChange: @escaping (String) -> Void) {
        if stringValue != value {
            stringValue = value
        }
        placeholderString = placeholder
        onValueChanged = onChange
    }

    func registerWithKeyboardFocusCoordinatorIfNeeded() {
        guard let window else { return }
        AppDelegate.shared?.keyboardFocusCoordinator(for: window)?.registerArtifactSearchField(self)
    }

    func focusFromCoordinator() -> Bool {
        window?.makeFirstResponder(self) == true
    }

    func ownsKeyboardFocus(_ responder: NSResponder) -> Bool {
        responder === self || currentEditor() === responder
    }

    @objc private func valueChanged() {
        onValueChanged?(stringValue)
    }
}
