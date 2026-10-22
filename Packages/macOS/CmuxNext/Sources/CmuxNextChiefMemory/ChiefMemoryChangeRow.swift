import AppKit
import CmuxNextDesign

/// One change in the change list, with its Undo button. Value snapshot and an action only (no
/// store below the list boundary).
final class ChiefMemoryChangeRow: NSView {
    private let undo: @MainActor () -> Void

    init(change: ChiefMemoryChange, undo: @escaping @MainActor () -> Void) {
        self.undo = undo
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: String(format: change.op == "delete" ? ChiefMemoryStrings.deleted : ChiefMemoryStrings.edited,
                                                        change.target.label))
        title.font = Typography.body
        let old = NSTextField(labelWithString: "")
        old.attributedStringValue = NSAttributedString(string: change.old, attributes: [
            .font: Typography.caption, .foregroundColor: NSColor.secondaryLabelColor,
            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
        ])
        old.lineBreakMode = .byTruncatingTail
        old.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var lines: [NSView] = [title, old]
        if change.op != "delete" {
            let new = NSTextField(labelWithString: change.new)
            new.font = Typography.caption
            new.lineBreakMode = .byTruncatingTail
            new.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            lines.append(new)
        }
        let text = NSStackView(views: lines)
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let trailing: NSView
        if change.undone {
            let done = NSTextField(labelWithString: ChiefMemoryStrings.undone)
            done.font = Typography.caption
            done.textColor = .secondaryLabelColor
            trailing = done
        } else {
            let button = NSButton(title: ChiefMemoryStrings.undo, target: self, action: #selector(undoClicked))
            button.bezelStyle = .push
            button.controlSize = .small
            button.setAccessibilityIdentifier("chief-memory.undo")
            trailing = button
        }
        trailing.setContentHuggingPriority(.required, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let line = NSStackView(views: [text, spacer, trailing])
        line.orientation = .horizontal
        line.alignment = .firstBaseline
        line.spacing = 8
        line.edgeInsets = NSEdgeInsets(top: 3, left: 0, bottom: 3, right: 0)
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.topAnchor.constraint(equalTo: topAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func undoClicked() { undo() }
}
