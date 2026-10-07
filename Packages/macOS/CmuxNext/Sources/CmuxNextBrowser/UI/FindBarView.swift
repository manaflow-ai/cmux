import AppKit
import CmuxNextDesign

/// Glass find-in-page capsule. Enter finds the next match, Shift-Enter the
/// previous one, Escape closes.
final class FindBarView: NSView {
    var onClose: (() -> Void)?
    weak var tab: (any BrowserTab)?

    private let field = ChromeTextField()
    private let countLabel = NSTextField(labelWithString: "")
    private var findTask: Task<Void, Never>?
    private let density = DensityBinding()
    private let icon = NSImageView()
    /// The bar's material: glass, or opaque under Reduce Transparency.
    private(set) var glass: OverlaySurfaceView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false


        field.setPlaceholder(Strings.findPlaceholder)
        field.delegate = self
        field.setAccessibilityLabel(Strings.findPlaceholder)

        countLabel.alignment = .right
        countLabel.setContentHuggingPriority(.required, for: .horizontal)

        let previous = ChromeIconButton(symbol: "chevron.up", label: Strings.findPrevious, action: #selector(findPrevious), target: self)
        let next = ChromeIconButton(symbol: "chevron.down", label: Strings.findNext, action: #selector(findNext), target: self)
        let done = ChromeIconButton(symbol: "xmark", label: Strings.findDone, action: #selector(close), target: self)

        let stack = NSStackView(views: [icon, field, countLabel, previous, next, done])
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = OverlayBackingView()
        content.addSubview(stack)
        let glass = Glass.makeOverlayPanel(content: content, cornerRadius: BrowserMetrics.overlayCornerRadius)
        addSubview(glass)
        self.glass = glass
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            density.bind(heightAnchor.constraint(equalToConstant: 0)) { BrowserMetrics.findBarHeight },
            // Preferred width: a narrow pane narrows the field.
            density.bind(field.widthAnchor.constraint(equalToConstant: 0).prioritized(.init(450))) { BrowserMetrics.findFieldWidth },
            density.bind(countLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 0).prioritized(.init(450))) {
                BrowserMetrics.findCountWidth
            },
        ])
        density.update { [countLabel, icon] in
            icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: BrowserMetrics.symbolPointSize - 1, weight: .semibold))
            countLabel.font = BrowserMetrics.countFont
            stack.spacing = BrowserMetrics.buttonSpacing
            stack.edgeInsets = NSEdgeInsets(top: 0, left: BrowserMetrics.overlayPadding, bottom: 0, right: BrowserMetrics.buttonSpacing)
            stack.setCustomSpacing(BrowserMetrics.itemSpacing, after: icon)
            stack.setCustomSpacing(BrowserMetrics.itemSpacing, after: countLabel)
            glass.cornerRadius = BrowserMetrics.overlayCornerRadius
        }
        density.start()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
    }

    private func applyColors() {
        performWithTheme {
            icon.contentTintColor = Palette.textSecondary
            countLabel.textColor = Palette.textSecondary
            glass?.applyTheme()
        }
    }

    func focus() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        if !field.stringValue.isEmpty { run(.forward) }
    }

    @objc func findNext() { run(.forward) }
    @objc func findPrevious() { run(.backward) }

    @objc func close() {
        findTask?.cancel()
        tab?.clearFind()
        onClose?()
    }

    private func run(_ direction: BrowserFindDirection) {
        findTask?.cancel()
        guard let tab else { return }
        let text = field.stringValue
        findTask = Task { [weak self] in
            let result = await tab.find(text, direction: direction, caseSensitive: false)
            guard !Task.isCancelled else { return }
            self?.show(result, for: text)
        }
    }

    private func show(_ result: BrowserFindResult, for text: String) {
        if text.isEmpty {
            countLabel.stringValue = ""
        } else if !result.matchFound {
            countLabel.stringValue = Strings.findNoMatches
        } else if let index = result.currentIndex, let count = result.matchCount {
            countLabel.stringValue = Strings.findPosition(index, of: count)
        } else if let count = result.matchCount {
            countLabel.stringValue = Strings.findCount(count)
        } else {
            countLabel.stringValue = ""
        }
    }
}

extension FindBarView: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        run(.forward)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { findPrevious() } else { findNext() }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            close()
            return true
        default:
            return false
        }
    }
}
