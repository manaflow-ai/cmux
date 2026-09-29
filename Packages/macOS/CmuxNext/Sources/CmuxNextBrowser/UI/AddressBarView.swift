public import AppKit
import CmuxNextDesign

/// The omnibox: a gray glass capsule that shows the compact URL, expands to
/// the full URL on focus, and offers suggestions while typing.
public final class AddressBarView: NSView {
    /// Called with the destination when the user submits.
    public var onNavigate: ((URL) -> Void)?
    /// Called when editing ends with Escape and focus should return to the page.
    public var onCancel: (() -> Void)?

    public var suggestionEngine: OmniboxSuggestionEngine

    private let glass: NSGlassEffectView
    private let focusOutline = NSView()
    private let iconView = NSImageView()
    private let field = AddressField()
    private let panel = OmniboxSuggestionPanel()

    private var url: URL?
    private var security: BrowserSecurityState = .none
    private var typedText = ""
    private var suggestions: [BrowserSuggestion] = []
    private var selectedIndex: Int?
    private var suggestionTask: Task<Void, Never>?

    public init(suggestionEngine: OmniboxSuggestionEngine = OmniboxSuggestionEngine()) {
        self.suggestionEngine = suggestionEngine
        let content = NSView()
        glass = Glass.makePanel(content: content, style: .regular, cornerRadius: 9)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentTintColor = Palette.textSecondary
        iconView.imageScaling = .scaleProportionallyDown

        field.setPlaceholder(Strings.addressPlaceholder)
        field.delegate = self
        field.onFocus = { [weak self] in self?.beginEditing() }
        field.setAccessibilityLabel(Strings.addressPlaceholder)

        focusOutline.translatesAutoresizingMaskIntoConstraints = false
        focusOutline.wantsLayer = true
        focusOutline.layer?.cornerRadius = 9
        focusOutline.layer?.borderWidth = 1
        focusOutline.alphaValue = 0

        content.addSubview(iconView)
        content.addSubview(field)
        addSubview(glass)
        addSubview(focusOutline)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            focusOutline.leadingAnchor.constraint(equalTo: leadingAnchor),
            focusOutline.trailingAnchor.constraint(equalTo: trailingAnchor),
            focusOutline.topAnchor.constraint(equalTo: topAnchor),
            focusOutline.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 28),

            iconView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 9),
            iconView.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),
            field.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 7),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            field.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        panel.onPick = { [weak self] index in self?.pick(index) }
        updateIcon()
        updateOutlineColor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Public

    public var isEditing: Bool { field.currentEditor() != nil }

    /// Shows the page's URL. Ignored while the user is typing.
    public func update(url: URL?, security: BrowserSecurityState) {
        self.url = url
        self.security = security
        guard !isEditing else { return }
        field.stringValue = BrowserURLDisplay.displayText(for: url)
        updateIcon()
    }

    /// Focuses the field and selects its text (Cmd-L).
    public func focus() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    // MARK: Editing

    private func beginEditing() {
        field.stringValue = BrowserURLDisplay.editingText(for: url)
        field.currentEditor()?.selectAll(nil)
        typedText = field.stringValue
        updateIcon()
        Motion.animate(duration: 0.12) { self.focusOutline.animator().alphaValue = 1 }
    }

    private func endEditing(restore: Bool) {
        suggestionTask?.cancel()
        panel.dismiss()
        suggestions = []
        selectedIndex = nil
        if restore {
            field.stringValue = BrowserURLDisplay.displayText(for: url)
        }
        updateIcon()
        Motion.animate(duration: 0.12) { self.focusOutline.animator().alphaValue = 0 }
    }

    private func textDidChange() {
        typedText = field.stringValue
        selectedIndex = nil
        suggestionTask?.cancel()
        let text = typedText
        let engine = suggestionEngine
        suggestionTask = Task { [weak self] in
            let rows = await engine.suggestions(for: text)
            guard !Task.isCancelled, let self, self.isEditing else { return }
            self.suggestions = rows
            self.selectedIndex = rows.isEmpty ? nil : 0
            self.showPanel()
        }
    }

    private func showPanel() {
        guard !suggestions.isEmpty, let window else {
            panel.dismiss()
            return
        }
        panel.show(suggestions, selected: selectedIndex, below: self, in: window)
    }

    private func moveSelection(_ delta: Int) {
        guard !suggestions.isEmpty else { return }
        let next = ((selectedIndex ?? -1) + delta).clamped(to: 0...(suggestions.count - 1))
        selectedIndex = next
        let row = suggestions[next]
        field.stringValue = next == 0 ? typedText : (row.kind == .search ? row.title : row.url.absoluteString)
        field.currentEditor()?.moveToEndOfDocument(nil)
        panel.select(next)
    }

    private func submit() {
        let destination: URL?
        if let selectedIndex, suggestions.indices.contains(selectedIndex) {
            destination = suggestions[selectedIndex].url
        } else {
            destination = suggestionEngine.resolver.destination(for: field.stringValue)?.url
        }
        guard let destination else { return }
        url = destination
        endEditing(restore: true)
        onNavigate?(destination)
    }

    private func pick(_ index: Int) {
        selectedIndex = index
        submit()
    }

    private func updateIcon() {
        let symbol: String
        if isEditing || url == nil {
            symbol = "magnifyingglass"
        } else {
            switch security {
            case .secure: symbol = "lock.fill"
            case .insecure: symbol = "exclamationmark.triangle"
            case .local: symbol = "doc"
            case .none: symbol = "globe"
            }
        }
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        iconView.setAccessibilityLabel(security == .insecure && !isEditing ? Strings.notSecure : nil)
    }

    private func updateOutlineColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            focusOutline.layer?.borderColor = Palette.focusRing.withAlphaComponent(0.45).cgColor
        }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateOutlineColor()
    }

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { panel.dismiss() }
    }
}

extension AddressBarView: NSTextFieldDelegate {
    public func controlTextDidChange(_ notification: Notification) {
        textDidChange()
    }

    public func controlTextDidEndEditing(_ notification: Notification) {
        endEditing(restore: true)
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(-1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            submit()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            if panel.isVisible {
                field.stringValue = typedText
                panel.dismiss()
                suggestions = []
                selectedIndex = nil
            } else {
                endEditing(restore: true)
                onCancel?()
            }
            return true
        default:
            return false
        }
    }
}

/// Text field that reports when it gains focus.
final class AddressField: ChromeTextField {
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
