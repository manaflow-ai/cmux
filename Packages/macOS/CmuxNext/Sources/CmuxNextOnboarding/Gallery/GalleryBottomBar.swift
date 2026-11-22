import AppKit
import CmuxNextDesign

/// "Theme · C  Tinted Rows" with its idea, the note field, and the actions;
/// the key map in one quiet line under them.
final class GalleryBottomBar: NSView, NSTextFieldDelegate {
    let label = OnboardingLabel.make(font: .systemFont(ofSize: 15, weight: .semibold))
    let detail = OnboardingLabel.make(font: OnboardingMetrics.captionFont, color: Palette.textSecondary)
    let note = NSTextField()
    let pick: NSButton
    let compare: NSButton
    let copy: NSButton
    let run: NSButton
    var onNote: ((String) -> Void)?
    static let keyMap = "← → variant · ↑ ↓ screen · 1–9 jump · P pick · Space compare · T light/dark · ↵ run flow · ⌘C copy feedback · Esc close"

    init(target: AnyObject, pick pickAction: Selector, compare compareAction: Selector, copy copyAction: Selector, run runAction: Selector) {
        pick = OnboardingControl.button("Pick (P)", prominent: true, target: target, action: pickAction)
        compare = OnboardingControl.button("Compare (Space)", target: target, action: compareAction)
        copy = OnboardingControl.button("Copy Feedback", target: target, action: copyAction)
        run = OnboardingControl.button("Run Flow (↵)", target: target, action: runAction)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        note.placeholderString = "Note for this variant"
        note.delegate = self
        note.translatesAutoresizingMaskIntoConstraints = false
        note.focusRingType = .none
        let keys = OnboardingLabel.make(Self.keyMap, font: OnboardingMetrics.captionFont, color: Palette.textTertiary)
        let text = NSStackView(views: [label, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        let buttons = NSStackView(views: [pick, compare, copy, run])
        buttons.spacing = 8
        for view in [text, note, buttons, keys] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20), text.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            text.widthAnchor.constraint(equalToConstant: 300),
            note.leadingAnchor.constraint(equalTo: text.trailingAnchor, constant: 16), note.centerYAnchor.constraint(equalTo: text.centerYAnchor),
            note.trailingAnchor.constraint(equalTo: buttons.leadingAnchor, constant: -16),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20), buttons.centerYAnchor.constraint(equalTo: text.centerYAnchor),
            keys.leadingAnchor.constraint(equalTo: text.leadingAnchor), keys.topAnchor.constraint(equalTo: text.bottomAnchor, constant: 10),
            keys.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func controlTextDidChange(_ notification: Notification) { onNote?(note.stringValue) }

    /// Return or Escape in the note field gives the keyboard back to the gallery.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) || selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        window?.makeFirstResponder(nil)
        return true
    }
}
