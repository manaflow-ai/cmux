import AppKit
import CmuxNextDesign
import Foundation

/// The Chief Settings card's Reactions block (a416, Lawrence 2026-10-21): whether a tapback the person puts
/// on a Chief message may start a turn, and the cheap classifier that decides it (its harness, model and
/// instructions). Each control shows this Chief's own value (engine.json); left at Default it runs the
/// person's (cmux.json `chief.reactionsCanWake`, `chief.reactionClassifier.*`), which its title or
/// placeholder names. A change is one `chief.engine.set` field through `onPick`; an emptied field clears
/// this Chief's own value.
@MainActor
final class HomeChiefReactionRows: NSStackView {
    /// Default (names what it runs), On, Off.
    let canWake = ThemedPopUpButton(frame: .zero, pullsDown: false)
    let harness = ThemedTextField(string: "")
    let model = ThemedTextField(string: "")
    let prompt = ThemedTextField(string: "")
    /// Sends `chief.engine.set` fields (nil clears one); the card writes them to the brain.
    var onPick: ([String: String?]) -> Void = { _ in }
    /// What each field showed at the last `show`, so leaving it unchanged writes nothing.
    private var shown: [ObjectIdentifier: String] = [:]

    init(width: CGFloat) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = Metrics.space2
        canWake.target = self
        canWake.action = #selector(pickedWake(_:))
        canWake.font = Typography.body
        canWake.setAccessibilityLabel(HomeEngineStrings.reactionsCanWake)
        add(HomeChiefSettingsView.row(HomeEngineStrings.reactionsCanWake, canWake))
        for (field, title, action) in [(harness, HomeEngineStrings.reactionHarness, #selector(editedHarness(_:))),
                                       (model, HomeEngineStrings.reactionModel, #selector(editedModel(_:))),
                                       (prompt, HomeEngineStrings.reactionPrompt, #selector(editedPrompt(_:)))] {
            field.target = self
            field.action = action
            // Leaving the field (a click elsewhere, the popover closing) keeps the value, as Return does.
            field.cell?.sendsActionOnEndEditing = true
            field.font = Typography.body
            field.setAccessibilityLabel(title)
            let box = ThemedFieldBox(field: field, height: Metrics.controlHeight)
            box.widthAnchor.constraint(equalToConstant: HomeChiefSettingsView.pickerWidth).isActive = true
            add(HomeChiefSettingsView.row(title, box))
        }
        let note = HomeChiefSettingsView.footnote(HomeEngineStrings.reactionsNote)
        note.preferredMaxLayoutWidth = width
        add(note)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func add(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }

    /// Shows this Chief's own values over what the brain resolved (`effective`).
    func show(_ snapshot: HomeChiefSnapshot) {
        let resolved = snapshot.effective
        let wakes = resolved?.reactionsCanWake ?? true
        canWake.removeAllItems()
        canWake.addItem(withTitle: String(format: HomeEngineStrings.defaultNamedFormat, wakes ? HomeEngineStrings.reactionsOn : HomeEngineStrings.reactionsOff))
        canWake.lastItem?.representedObject = nil
        for (value, title) in [("true", HomeEngineStrings.reactionsOn), ("false", HomeEngineStrings.reactionsOff)] {
            canWake.addItem(withTitle: title)
            canWake.lastItem?.representedObject = value
        }
        let own = snapshot.reactionsCanWake.flatMap { ["true", "false"].contains($0) ? $0 : nil }
        canWake.selectItem(at: own.flatMap { value in canWake.itemArray.firstIndex { $0.representedObject as? String == value } } ?? 0)
        fill(harness, own: snapshot.classifierHarness, placeholder: Self.named(resolved?.classifierHarness, else: HomeEngineStrings.reactionHarnessDefault))
        fill(model, own: snapshot.classifierModel, placeholder: Self.named(resolved?.classifierModel, else: HomeEngineStrings.defaultValue))
        fill(prompt, own: snapshot.classifierPrompt, placeholder: resolved?.classifierPrompt.flatMap { $0.isEmpty ? nil : $0 } ?? HomeEngineStrings.reactionPromptBuiltIn)
    }

    /// "Default (value)" for a resolved value, else `fallback`.
    private static func named(_ value: String?, else fallback: String) -> String {
        guard let value, !value.isEmpty, value != "default" else { return fallback }
        return String(format: HomeEngineStrings.defaultNamedFormat, value)
    }

    private func fill(_ field: NSTextField, own: String?, placeholder: String) {
        let text = own.flatMap { $0 == "default" ? nil : $0 } ?? ""
        if field.currentEditor() == nil { field.stringValue = text }
        field.placeholderString = placeholder
        shown[ObjectIdentifier(field)] = text
    }

    @objc func pickedWake(_ sender: NSPopUpButton) {
        onPick(["reactions_can_wake": sender.selectedItem?.representedObject as? String])
    }

    @objc func editedHarness(_ sender: NSTextField) { edited(sender, "classifier_harness") }
    @objc func editedModel(_ sender: NSTextField) { edited(sender, "classifier_model") }
    @objc func editedPrompt(_ sender: NSTextField) { edited(sender, "classifier_prompt") }

    private func edited(_ field: NSTextField, _ key: String) {
        guard field.stringValue != shown[ObjectIdentifier(field)] else { return }
        shown[ObjectIdentifier(field)] = field.stringValue
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        onPick([key: value.isEmpty ? nil : value])
    }
}
