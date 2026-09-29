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

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold)) ?? NSImage())
        icon.contentTintColor = Palette.textSecondary

        field.setPlaceholder(Strings.findPlaceholder)
        field.delegate = self
        field.setAccessibilityLabel(Strings.findPlaceholder)

        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = Palette.textSecondary
        countLabel.alignment = .right
        countLabel.setContentHuggingPriority(.required, for: .horizontal)

        let previous = ChromeIconButton(symbol: "chevron.up", label: Strings.findPrevious, action: #selector(findPrevious), target: self)
        let next = ChromeIconButton(symbol: "chevron.down", label: Strings.findNext, action: #selector(findNext), target: self)
        let done = ChromeIconButton(symbol: "xmark", label: Strings.findDone, action: #selector(close), target: self)

        let stack = NSStackView(views: [icon, field, countLabel, previous, next, done])
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 4)
        stack.setCustomSpacing(8, after: icon)
        stack.setCustomSpacing(8, after: countLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = OverlayBackingView()
        content.addSubview(stack)
        let glass = Glass.makePanel(content: content, style: .regular, cornerRadius: 12)
        addSubview(glass)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 36),
            field.widthAnchor.constraint(equalToConstant: 180),
            countLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 64),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

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
