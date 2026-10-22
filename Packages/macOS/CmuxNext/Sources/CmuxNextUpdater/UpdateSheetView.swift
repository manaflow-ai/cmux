import AppKit
import CmuxNextDesign

/// The compact update sheet body, in AppKit (plans/cmux-next/no-swiftui-DESIGN.md). Hosted in a
/// glass panel by ``UpdateSheetController``; gray chrome only (no accent color). ``show(_:)``
/// rebuilds the views only when the content changes.
final class UpdateSheetView: NSView {
    private let press: @MainActor (UpdateSheetButton) -> Void
    private let stack = NSStackView()
    private(set) var content: UpdateSheetContent?
    private var buttonsByID: [String: UpdateSheetButton] = [:]

    /// - Parameter press: Runs a pressed button (the controller performs it and closes the sheet when it dismisses).
    init(press: @escaping @MainActor (UpdateSheetButton) -> Void) {
        self.press = press
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.space5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Metrics.paletteWidth / 2),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.space6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.space6),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.space6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Metrics.space6),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    nonisolated override var isFlipped: Bool { true }

    /// Shows `next`; nil empties the body. Does nothing when the content did not change.
    func show(_ next: UpdateSheetContent?) {
        guard next != content || (next != nil && stack.arrangedSubviews.isEmpty) else { return }
        content = next
        for view in stack.arrangedSubviews { view.removeFromSuperview() }
        buttonsByID = [:]
        guard let next else { return }
        let top = NSStackView(views: [symbol(next), text(next)])
        top.orientation = .horizontal
        top.alignment = .top
        top.spacing = Metrics.space5
        stack.addArrangedSubview(top)
        top.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        if let row = buttonRow(next) {
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    private func symbol(_ content: UpdateSheetContent) -> NSView {
        let config = NSImage.SymbolConfiguration(pointSize: Metrics.iconSize * 1.6, weight: .regular)
        let image = NSImage(systemSymbolName: content.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) ?? NSImage()
        let view = ThemedImageView(image: image)
        view.ink = .secondary
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: Metrics.iconSize * 2).isActive = true
        view.setContentHuggingPriority(.required, for: .horizontal)
        // Indeterminate progress turns the symbol (pulses on macOS 14, which has no rotate effect);
        // still while loops are off (Reduce Motion or `ui.animationSpeed` off; cx-sya4n).
        if content.progress == .indeterminate, Motion.indicators.animatesLoops {
            if #available(macOS 15, *) {
                // motion: allow the effect runs only while Motion.indicators.animatesLoops (checked above)
                view.addSymbolEffect(.rotate)
            } else {
                // motion: allow the effect runs only while Motion.indicators.animatesLoops (checked above)
                view.addSymbolEffect(.pulse)
            }
        }
        return view
    }

    private func text(_ content: UpdateSheetContent) -> NSView {
        let width = Metrics.paletteWidth / 2 - Metrics.space6 * 2 - Metrics.iconSize * 2 - Metrics.space5
        let title = ThemedLabel(wrappingLabelWithString: content.title)
        title.font = Typography.bodyEmphasized
        title.preferredMaxLayoutWidth = width
        title.setAccessibilityLabel(content.title)
        var views: [NSView] = [title]
        if let detail = content.detail {
            let label = ThemedLabel(wrappingLabelWithString: detail)
            label.font = Typography.caption
            label.ink = .secondary
            label.isSelectable = true
            label.preferredMaxLayoutWidth = width
            label.setAccessibilityLabel(detail)
            views.append(label)
        }
        switch content.progress {
        case .none: break
        case .indeterminate: views.append(progressBar(value: nil))
        case .fraction(let value): views.append(progressBar(value: value))
        }
        let column = NSStackView(views: views)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = Metrics.space2
        column.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in views { view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        return column
    }

    private func progressBar(value: Double?) -> NSView {
        let bar = UpdateSheetProgressBar(fraction: value)
        let box = NSStackView(views: [bar])
        box.edgeInsets = NSEdgeInsets(top: Metrics.space2, left: 0, bottom: 0, right: 0)
        bar.widthAnchor.constraint(equalTo: box.widthAnchor).isActive = true
        return box
    }

    private func buttonRow(_ content: UpdateSheetContent) -> NSView? {
        guard content.link != nil || !content.buttons.isEmpty else { return nil }
        var views: [NSView] = []
        if let link = content.link {
            let button = NSButton(title: link.title, target: self, action: #selector(buttonPressed(_:)))
            button.isBordered = false
            performWithTheme {
                button.attributedTitle = NSAttributedString(string: link.title, attributes: [
                    .font: Typography.caption, .foregroundColor: Palette.textSecondary,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ])
            }
            views.append(tag(button, link))
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        views.append(spacer)
        // The last button is Return's; the first other one that closes the sheet, Escape's.
        let cancel = content.buttons.dropLast().firstIndex(where: \.dismisses)
        for (index, item) in content.buttons.enumerated() {
            let role: CmuxDialogButton.Role = index == content.buttons.count - 1 ? .default : (index == cancel ? .cancel : .normal)
            let view = CmuxDialogButtonView(standalone: CmuxDialogButton(id: item.id, title: item.title, role: role),
                                            target: self, action: #selector(buttonPressed(_:)))
            views.append(tag(view, item))
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = Metrics.space4
        return row
    }

    private func tag(_ view: NSButton, _ button: UpdateSheetButton) -> NSButton {
        view.setAccessibilityIdentifier("cmux.update.button.\(button.id)")
        buttonsByID[button.id] = button
        return view
    }

    @objc private func buttonPressed(_ sender: NSButton) {
        let id = sender.accessibilityIdentifier().replacingOccurrences(of: "cmux.update.button.", with: "")
        guard let button = buttonsByID[id] else { return }
        press(button)
    }
}

extension UpdateSheetButton {
    /// A stable id for the button's view (accessibility identifier `cmux.update.button.<id>`).
    var id: String {
        switch self {
        case .install: "install"
        case .later: "later"
        case .cancel: "cancel"
        case .retry: "retry"
        case .done: "done"
        case .relaunch: "relaunch"
        case .releaseNotes: "releaseNotes"
        case .downloadManually: "downloadManually"
        }
    }
}
