import AppKit
import CmuxHomeCore
import CmuxHomeRender
import CmuxNextDesign

/// The tapback row at the top of a bubble's context menu: one emoji button
/// per tapback, each with its localized name as the accessibility label.
/// Tapbacks I already gave are shown selected (a theme fill and the
/// accessibility selected state); choosing one again sends nothing (the
/// owner keeps one of each and has no remove op). The model
/// (`HomeReactionTarget`, `HomeReactionStyle`) is shared with iOS.
final class HomeTapbackPickerView: NSView {
    static let buttonSize: CGFloat = 32
    static let spacing: CGFloat = 4
    static let inset = NSEdgeInsets(top: 4, left: 12, bottom: 4, right: 12)

    let target: HomeReactionTarget
    private let onChoose: (Reaction.Tapback) -> Void
    private(set) var buttons: [NSButton] = []

    init(target: HomeReactionTarget, onChoose: @escaping (Reaction.Tapback) -> Void) {
        self.target = target
        self.onChoose = onChoose
        let count = CGFloat(HomeReactionStyle.tapbacks.count)
        let width = Self.inset.left + Self.inset.right + count * Self.buttonSize + (count - 1) * Self.spacing
        let height = Self.inset.top + Self.inset.bottom + Self.buttonSize
        super.init(frame: CGRect(x: 0, y: 0, width: width, height: height))
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(HomeReactionStyle.pickerLabel)
        for (i, tapback) in HomeReactionStyle.tapbacks.enumerated() {
            let button = makeButton(tapback)
            button.frame = CGRect(x: Self.inset.left + CGFloat(i) * (Self.buttonSize + Self.spacing), y: Self.inset.bottom,
                                  width: Self.buttonSize, height: Self.buttonSize)
            addSubview(button)
            buttons.append(button)
        }
        updateColors()
    }

    required init?(coder: NSCoder) { nil }

    private func makeButton(_ tapback: Reaction.Tapback) -> NSButton {
        let button = NSButton(title: HomeReactionStyle.glyph(tapback), target: self, action: #selector(choose(_:)))
        button.setButtonType(.momentaryChange)
        button.isBordered = false
        button.font = .systemFont(ofSize: 18)
        button.tag = HomeReactionStyle.tapbacks.firstIndex(of: tapback) ?? 0
        button.setAccessibilitySelected(target.chosen.contains(tapback))
        button.wantsLayer = true
        button.layer?.cornerRadius = Self.buttonSize / 2
        button.setAccessibilityLabel(HomeReactionStyle.accessibilityName(tapback))
        button.setAccessibilityIdentifier("home.tapback.\(tapback.rawValue)")
        return button
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        performWithTheme {
            for (button, tapback) in zip(buttons, HomeReactionStyle.tapbacks) {
                button.layer?.backgroundColor = target.chosen.contains(tapback) ? Palette.selectionFill.cgColor : nil
            }
        }
    }

    @objc func choose(_ sender: NSButton) {
        let tapback = HomeReactionStyle.tapbacks[sender.tag]
        // The owner's echo is the only source of truth for the selection;
        // choosing a tapback I already gave closes the menu and sends nothing.
        enclosingMenuItem?.menu?.cancelTracking()
        onChoose(tapback)
    }
}
