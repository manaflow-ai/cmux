import AppKit
import CmuxChief

/// Chief's settings, a right panel inside the transcript that the header's
/// "Chief >" name pill toggles (cmux-next `HomeChiefSidebar`): the avatar,
/// which agent answers (harness, model, effort; the `chief.*` cmux
/// settings, applied from the next turn), Chief's memory files, and a new
/// conversation.
@MainActor
final class ChiefSettingsPanel: NSView {
    static let width: CGFloat = 280

    private let stack = NSStackView()
    private let memorySection = ChiefMemorySectionView(width: ChiefSettingsPanel.width - 32)
    private let harness = NSPopUpButton(frame: .zero, pullsDown: false)
    private let model = NSPopUpButton(frame: .zero, pullsDown: false)
    private let effort = NSPopUpButton(frame: .zero, pullsDown: false)
    private let avatarField = NSTextField(string: "")
    private var captions: [NSTextField] = []
    private var notes: [NSTextField] = []
    private var titleLabel = NSTextField(labelWithString: ChiefStrings.settingsTitle)
    private var shownAvatar = ""
    /// Choose Picture… without a picture, Remove Picture with one.
    private let pictureButton = NSButton(title: ChiefStrings.settingsAvatarChoosePicture, target: nil, action: nil)
    private var hasPicture = false

    /// The avatar text changed (nil: initials).
    var onAvatar: (String?) -> Void = { _ in }
    /// Choose Picture… was clicked: the host opens the image picker.
    var onChoosePicture: () -> Void = {}
    /// Remove Picture was clicked.
    var onRemovePicture: () -> Void = {}
    /// New Conversation was clicked.
    var onNewConversation: () -> Void = {}
    /// Edit About You / Edit Instructions: the host opens the editor.
    var onEditMemory: (_ instructions: Bool) -> Void = { _ in }
    /// Show in Finder.
    var onShowMemoryFolder: () -> Void = {}

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(ChiefStrings.settingsTitle)
        setAccessibilityIdentifier("ChiefSettingsPanel")
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.addArrangedSubview(titleLabel)
        stack.setCustomSpacing(14, after: titleLabel)

        avatarField.placeholderString = ChiefStrings.settingsAvatarPlaceholder
        avatarField.target = self
        avatarField.action = #selector(avatarChanged)
        avatarField.setAccessibilityLabel(ChiefStrings.settingsAvatar)
        addRow(ChiefStrings.settingsAvatar, avatarField)
        stack.setCustomSpacing(6, after: avatarField)
        pictureButton.target = self
        pictureButton.action = #selector(pictureClicked)
        pictureButton.bezelStyle = .push
        pictureButton.controlSize = .regular
        stack.addArrangedSubview(pictureButton)
        pictureButton.widthAnchor.constraint(equalToConstant: Self.width - 32).isActive = true
        stack.setCustomSpacing(10, after: pictureButton)

        for (button, label) in [(harness, ChiefStrings.settingsHarness), (model, ChiefStrings.settingsModel),
                                (effort, ChiefStrings.settingsEffort)] {
            button.target = self
            button.action = #selector(picked(_:))
            button.setAccessibilityLabel(label)
            addRow(label, button)
        }
        addNote(ChiefStrings.settingsNextTurn)
        if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(22, after: last) }

        addCaption(ChiefStrings.settingsMemory)
        addNote(ChiefStrings.settingsMemoryNote)
        // Chief memory (ChiefMemorySectionView): the newest notes, hover ✕ forgets, Show All… opens the sheet.
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last ?? titleLabel)
        memorySection.onShowAll = { [weak self] in ChiefMemoryEditor.present(selecting: .notes, in: self?.window) }
        stack.addArrangedSubview(memorySection)
        stack.setCustomSpacing(10, after: memorySection)
        for (title, action) in [(ChiefStrings.settingsEditProfile, #selector(editProfile)),
                                (ChiefStrings.settingsEditInstructions, #selector(editInstructions)),
                                (ChiefStrings.settingsShowMemoryFolder, #selector(showFolder))] {
            addButton(title, action)
        }
        if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(22, after: last) }
        addCaption(ChiefStrings.settingsConversation)
        addButton(ChiefStrings.newConversation, #selector(newConversation))
        addSubview(stack)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    private func addCaption(_ text: String) {
        let caption = NSTextField(labelWithString: text)
        caption.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        captions.append(caption)
        stack.addArrangedSubview(caption)
    }

    private func addRow(_ label: String, _ control: NSControl) {
        addCaption(label)
        control.controlSize = .regular
        stack.addArrangedSubview(control)
        control.widthAnchor.constraint(equalToConstant: Self.width - 32).isActive = true
        stack.setCustomSpacing(10, after: control)
    }

    private func addNote(_ text: String) {
        let note = NSTextField(wrappingLabelWithString: text)
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.preferredMaxLayoutWidth = Self.width - 32
        notes.append(note)
        stack.addArrangedSubview(note)
    }

    private func addButton(_ title: String, _ action: Selector) {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .push
        button.controlSize = .regular
        stack.addArrangedSubview(button)
        button.widthAnchor.constraint(equalToConstant: Self.width - 32).isActive = true
    }

    // MARK: Theme

    func apply(_ theme: ChiefTheme) {
        layer?.backgroundColor = theme.panelFill.cgColor
        appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        titleLabel.textColor = theme.textPrimary
        for caption in captions { caption.textColor = theme.textSecondary }
        for note in notes { note.textColor = theme.textTertiary }
        memorySection.apply(theme)
    }

    override func layout() {
        super.layout()
        let size = stack.fittingSize
        stack.frame = CGRect(x: 0, y: 0, width: Self.width, height: max(size.height, bounds.height))
    }

    // MARK: Values

    /// Shows the current engine settings and avatar.
    func refresh(avatar: String? = nil, hasPicture: Bool? = nil) {
        if let hasPicture {
            self.hasPicture = hasPicture
            pictureButton.title = hasPicture ? ChiefStrings.settingsAvatarRemovePicture : ChiefStrings.settingsAvatarChoosePicture
        }
        let settings = ChiefService.shared.engineSettings
        let harnessValue = settings.resolvedHarness
        fill(harness, CmuxChief.ChiefHarness.allCases.map { ($0.rawValue, $0.rawValue) },
             current: settings.harness.isEmpty ? nil : settings.harness, includesDefault: true)
        fill(model, ChiefModelCatalog.models(for: harnessValue).map { ($0.id, $0.displayName) },
             current: settings.model.isEmpty ? nil : settings.model, includesDefault: true)
        fill(effort, ChiefModelCatalog.efforts(for: settings.resolvedModel, harness: harnessValue)
                .map { ($0.id, ChiefStrings.effortName($0.id)) },
             current: settings.effort.isEmpty ? nil : settings.effort, includesDefault: true)
        if let avatar, avatarField.currentEditor() == nil {
            shownAvatar = avatar
            avatarField.stringValue = avatar
        }
    }

    /// `values` with "Default" first (when offered), keeping a current value
    /// the catalog does not list.
    private func fill(_ button: NSPopUpButton, _ values: [(value: String, title: String)], current: String?,
                      includesDefault: Bool) {
        button.removeAllItems()
        if includesDefault {
            button.addItem(withTitle: ChiefStrings.settingsDefault)
            button.lastItem?.representedObject = nil
        }
        var all = values
        if let current, !all.contains(where: { $0.value == current }) { all.append((current, current)) }
        for item in all {
            button.addItem(withTitle: item.title)
            button.lastItem?.representedObject = item.value
        }
        let offset = includesDefault ? 1 : 0
        if let current, let index = all.firstIndex(where: { $0.value == current }) {
            button.selectItem(at: index + offset)
        } else {
            button.selectItem(at: 0)
        }
    }

    @objc private func picked(_ sender: NSPopUpButton) {
        var settings = ChiefService.shared.engineSettings
        let value = sender.selectedItem?.representedObject as? String ?? ""
        if sender === harness {
            guard value != settings.harness else { return }
            let before = settings.resolvedHarness
            settings.harness = value
            if settings.resolvedHarness != before {
                // Models belong to one harness; an effort the new default model lacks goes too.
                settings.model = ""
                let offered = ChiefModelCatalog.efforts(for: settings.resolvedModel, harness: settings.resolvedHarness)
                if !offered.contains(where: { $0.id == settings.effort }) { settings.effort = "" }
            }
        } else if sender === model {
            settings.model = value
        } else {
            settings.effort = value
        }
        ChiefService.shared.setEngineSettings(settings)
        refresh()
    }

    @objc private func avatarChanged() {
        let text = ChiefProfile.avatarText(avatarField.stringValue) ?? ""
        avatarField.stringValue = text
        guard text != shownAvatar else { return }
        shownAvatar = text
        onAvatar(text.isEmpty ? nil : text)
    }

    @objc private func pictureClicked() {
        if hasPicture { onRemovePicture() } else { onChoosePicture() }
    }

    @objc private func editProfile() { onEditMemory(false) }
    @objc private func editInstructions() { onEditMemory(true) }
    @objc private func showFolder() { onShowMemoryFolder() }
    @objc private func newConversation() { onNewConversation() }
}
