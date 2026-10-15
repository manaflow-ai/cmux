import AppKit
import CmuxChief
import CmuxHomeCore
import Observation

/// Chief's settings, a right panel inside the transcript that the header's
/// "Chief >" name pill toggles (cmux-next `HomeChiefSidebar`, feat-cmux-next
/// `Packages/macOS/CmuxNext/Sources/CmuxNextHomeEngine/HomeChiefSidebar.swift`).
/// Grouped sections, each a rounded card:
///
/// - Profile: Chief's name and avatar.
/// - Brain: harness, model and effort (the `chief.*` cmux settings, applied
///   from the next turn). Each picker's first item names what the default
///   resolves to ("Default (Opus 5.5)"), the menus check the current choice,
///   and a line under Effort says what the level trades (references:
///   `apps/claude/live/model-picker-open.png`, `model-effort-submenu.png`,
///   `apps/aside/web/reasoning-menu.webp`).
/// - Activity: the last turn's engine, time, tool calls and cache share, where
///   the brain runs, and Show Transcript Log.
/// - Memory (``ChiefMemorySectionView``: the newest notes, Show All… for the
///   memory sheet) and Conversation.
@MainActor
final class ChiefSettingsPanel: NSView {
    static let width: CGFloat = 280
    private static let inset: CGFloat = 12
    private static let padding: CGFloat = 12
    private static let cardWidth = width - 2 * inset
    private static let contentWidth = cardWidth - 2 * padding

    private let scrollView = NSScrollView()
    private let document = ChiefSettingsDocumentView()
    private let stack = NSStackView()
    private let titleLabel = NSTextField(labelWithString: ChiefStrings.settingsTitle)
    private var cards: [ChiefSettingsCard] = []

    private let nameField = NSTextField(string: "")
    private let avatarField = NSTextField(string: "")
    /// Choose Picture… without a picture, Remove Picture with one.
    private let pictureButton = NSButton(title: ChiefStrings.settingsAvatarChoosePicture, target: nil, action: nil)
    private let harness = NSPopUpButton(frame: .zero, pullsDown: false)
    private let model = NSPopUpButton(frame: .zero, pullsDown: false)
    private let effort = NSPopUpButton(frame: .zero, pullsDown: false)
    private var effortNote = NSTextField(labelWithString: "")
    private var statsLabel = NSTextField(labelWithString: "")
    private var placeLabel = NSTextField(labelWithString: "")
    private let logButton = NSButton(title: ChiefSettingsStrings.showTranscriptLog, target: nil, action: nil)
    private let memorySection = ChiefMemorySectionView(width: ChiefSettingsPanel.contentWidth)
    private let newConversationButton = NSButton(title: ChiefStrings.newConversation, target: nil, action: nil)

    private var shownAvatar = ""
    private var shownName = ""
    private var hasPicture = false
    private var stopped = false
    // task-owner: the latest stats read; replaced by the next, cancelled by stop()
    private var statsRead: Task<Void, Never>?

    /// The conversation whose last turn the Activity section shows.
    var conversation: ConversationID? { didSet { if conversation != oldValue { refreshStats() } } }

    /// The name changed (nil: back to "Chief").
    var onName: (String?) -> Void = { _ in }
    /// The avatar text changed (nil: initials).
    var onAvatar: (String?) -> Void = { _ in }
    /// Choose Picture… was clicked: the host opens the image picker.
    var onChoosePicture: () -> Void = {}
    /// Remove Picture was clicked.
    var onRemovePicture: () -> Void = {}
    /// Show Transcript Log was clicked.
    var onShowTranscriptLog: () -> Void = {}
    /// New Conversation was clicked.
    var onNewConversation: () -> Void = {}

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(ChiefStrings.settingsTitle)
        setAccessibilityIdentifier("ChiefSettingsPanel")
        buildScroller()
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.setAccessibilityRole(.staticText)
        stack.addArrangedSubview(titleLabel)
        stack.setCustomSpacing(16, after: titleLabel)
        buildProfile()
        buildBrain()
        buildActivity()
        buildMemory()
        buildConversation()
        chainKeyViews()
        refresh()
        observeWorking()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    /// Ends the stats read and the working-set observation.
    func stop() {
        stopped = true
        statsRead?.cancel()
    }

    // MARK: Building

    private func buildScroller() {
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false
        addSubview(scrollView)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 16, left: Self.inset, bottom: 20, right: Self.inset)
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scrollView.documentView = document
        let clip = scrollView.contentView
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            document.topAnchor.constraint(equalTo: clip.topAnchor),
            document.widthAnchor.constraint(equalTo: clip.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
    }

    private func card(_ title: String) -> ChiefSettingsCard {
        let card = ChiefSettingsCard(title: title, width: Self.cardWidth, padding: Self.padding)
        cards.append(card)
        stack.addArrangedSubview(card)
        return card
    }

    private func buildProfile() {
        let profile = card(ChiefSettingsStrings.sectionProfile)
        configure(nameField, placeholder: ChiefStrings.chiefName, action: #selector(nameChanged))
        nameField.setAccessibilityIdentifier("ChiefSettingsName")
        profile.addRow(ChiefSettingsStrings.name, nameField)
        profile.addCaption(ChiefSettingsStrings.nameHelp, describing: nameField)
        profile.addGap(12)
        configure(avatarField, placeholder: ChiefStrings.settingsAvatarPlaceholder, action: #selector(avatarChanged))
        profile.addRow(ChiefStrings.settingsAvatar, avatarField)
        configure(pictureButton, action: #selector(pictureClicked))
        profile.add(pictureButton)
    }

    private func buildBrain() {
        let brain = card(ChiefSettingsStrings.sectionBrain)
        for (index, (button, label)) in [(harness, ChiefStrings.settingsHarness), (model, ChiefStrings.settingsModel),
                                         (effort, ChiefStrings.settingsEffort)].enumerated() {
            button.target = self
            button.action = #selector(picked(_:))
            button.setAccessibilityIdentifier("ChiefSettings\(["Harness", "Model", "Effort"][index])")
            brain.addRow(label, button)
            if button !== effort { brain.addGap(10) }
        }
        effortNote = brain.addCaption("", describing: effort)
        brain.addGap(10)
        brain.addCaption(ChiefStrings.settingsNextTurn)
    }

    private func buildActivity() {
        let activity = card(ChiefSettingsStrings.sectionActivity)
        statsLabel = activity.addCaption(ChiefSettingsStrings.noTurn)
        statsLabel.setAccessibilityIdentifier("ChiefSettingsLastTurn")
        statsLabel.isSelectable = true
        placeLabel = activity.addCaption("")
        placeLabel.isSelectable = true
        activity.addGap(10)
        configure(logButton, action: #selector(showLog))
        logButton.toolTip = ChiefSettingsStrings.showTranscriptLogHelp
        logButton.setAccessibilityHelp(ChiefSettingsStrings.showTranscriptLogHelp)
        activity.add(logButton)
    }

    private func buildMemory() {
        let memory = card(ChiefStrings.settingsMemory)
        memory.addCaption(ChiefStrings.settingsMemoryNote)
        memory.addGap(8)
        // Chief memory (ChiefMemorySectionView): the newest notes, hover ✕ forgets, Show All… opens the sheet.
        memorySection.onShowAll = { [weak self] in ChiefMemoryEditor.present(selecting: .notes, in: self?.window) }
        memory.box.addArrangedSubview(memorySection)
    }

    private func buildConversation() {
        let conversation = card(ChiefStrings.settingsConversation)
        configure(newConversationButton, action: #selector(newConversation))
        conversation.add(newConversationButton)
    }

    private func configure(_ field: NSTextField, placeholder: String, action: Selector) {
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 13)
        field.target = self
        field.action = action
        field.cell?.sendsActionOnEndEditing = true
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
    }

    private func configure(_ button: NSButton, action: Selector) {
        button.target = self
        button.action = action
        button.bezelStyle = .push
        button.controlSize = .regular
    }

    /// Tab moves top to bottom through the panel's controls.
    private func chainKeyViews() {
        // The memory section's own buttons (Show All…) sit between Activity and Conversation.
        let memory = Self.buttons(in: memorySection)
        let order: [NSView] = [nameField, avatarField, pictureButton, harness, model, effort, logButton] + memory
            + [newConversationButton]
        for (view, next) in zip(order, order.dropFirst()) { view.nextKeyView = next }
    }

    private static func buttons(in view: NSView) -> [NSButton] {
        view.subviews.flatMap { subview -> [NSButton] in
            if let button = subview as? NSButton, !button.title.isEmpty { return [button] }
            return buttons(in: subview)
        }
    }

    // MARK: Theme

    func apply(_ theme: ChiefTheme) {
        layer?.backgroundColor = theme.panelFill.cgColor
        appearance = theme.appearance
        titleLabel.textColor = theme.textPrimary
        for card in cards { card.apply(theme) }
        memorySection.apply(theme)
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
    }

    // MARK: Values

    /// Shows the current engine settings, and the name and avatar when given.
    func refresh(avatar: String? = nil, hasPicture: Bool? = nil, name: String? = nil) {
        if let hasPicture {
            self.hasPicture = hasPicture
            pictureButton.title = hasPicture ? ChiefStrings.settingsAvatarRemovePicture : ChiefStrings.settingsAvatarChoosePicture
        }
        if let avatar, avatarField.currentEditor() == nil {
            shownAvatar = avatar
            avatarField.stringValue = avatar
        }
        if let name, nameField.currentEditor() == nil {
            shownName = name
            nameField.stringValue = name
        }
        let settings = ChiefService.shared.engineSettings
        let harnessValue = settings.resolvedHarness
        fill(harness, CmuxChief.ChiefHarness.allCases.map { ($0.rawValue, $0.displayName) },
             current: settings.harness.isEmpty ? nil : settings.harness,
             defaultTitle: ChiefSettingsStrings.defaultItem(CmuxChief.ChiefHarness.claude.displayName))
        let defaultModel = harnessValue.defaultModel
        fill(model, harnessValue.models
                .map { ($0.id, ChiefSettingsStrings.modelName($0.id, harness: harnessValue.rawValue)) },
             current: settings.model.isEmpty ? nil : settings.model,
             defaultTitle: ChiefSettingsStrings.defaultItem(ChiefSettingsStrings.modelName(defaultModel,
                                                                                           harness: harnessValue.rawValue)))
        fill(effort, harnessValue.efforts(for: settings.resolvedModel)
                .map { ($0.id, ChiefStrings.effortName($0.id)) },
             current: settings.effort.isEmpty ? nil : settings.effort, defaultTitle: ChiefStrings.settingsDefault)
        effortNote.stringValue = ChiefSettingsStrings.effortDescription(settings.effort)
        effort.setAccessibilityHelp(effortNote.stringValue)
        placeLabel.stringValue = ChiefService.shared.homeDisplayPath.map(ChiefSettingsStrings.runsOnThisMac) ?? ""
        placeLabel.isHidden = placeLabel.stringValue.isEmpty
        refreshStats()
    }

    /// `values` after a "Default (…)" item and a separator, keeping a current
    /// value the catalog does not list; the menu checks the selected item.
    private func fill(_ button: NSPopUpButton, _ values: [(value: String, title: String)], current: String?,
                      defaultTitle: String) {
        button.removeAllItems()
        let menu = button.menu ?? NSMenu()
        let first = NSMenuItem(title: defaultTitle, action: nil, keyEquivalent: "")
        menu.addItem(first)
        menu.addItem(.separator())
        var all = values
        if let current, !all.contains(where: { $0.value == current }) { all.append((current, current)) }
        var selected = first
        for value in all {
            let item = NSMenuItem(title: value.title, action: nil, keyEquivalent: "")
            item.representedObject = value.value
            menu.addItem(item)
            if value.value == current { selected = item }
        }
        if button.menu == nil { button.menu = menu }
        button.select(selected)
    }

    /// Re-reads the last turn's stats from the owner.
    private func refreshStats() {
        statsRead?.cancel()
        guard let conversation, !stopped else {
            statsLabel.stringValue = ChiefSettingsStrings.noTurn
            return
        }
        statsRead = Task { [weak self] in
            let stats = await ChiefService.shared.lastTurnStats(in: conversation)
            guard !Task.isCancelled, let self else { return }
            self.statsLabel.stringValue = stats.map(ChiefSettingsStrings.lastTurn) ?? ChiefSettingsStrings.noTurn
        }
    }

    /// A turn's end changes the working set: the stats read again (Observation, no polling).
    private func observeWorking() {
        guard !stopped else { return }
        withObservationTracking {
            _ = ChiefService.shared.workingConversations
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshStats()
                self?.observeWorking()
            }
        }
    }

    // MARK: Actions

    @objc private func picked(_ sender: NSPopUpButton) {
        var settings = ChiefService.shared.engineSettings
        let value = sender.selectedItem?.representedObject as? String ?? ""
        if sender === harness {
            guard value != settings.harness else { return }
            let before = settings.resolvedHarness
            settings.harness = value
            if settings.resolvedHarness != before {
                // Models belong to one harness.
                settings.model = ""
            }
        } else if sender === model {
            settings.model = value
        } else {
            settings.effort = value
        }
        // An effort the new model lacks goes back to the default.
        let offered = settings.resolvedHarness.efforts(for: settings.resolvedModel)
        if !settings.effort.isEmpty, !offered.contains(where: { $0.id == settings.effort }) { settings.effort = "" }
        ChiefService.shared.setEngineSettings(settings)
        refresh()
    }

    @objc private func nameChanged() {
        let text = String(nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        nameField.stringValue = text
        guard text != shownName else { return }
        shownName = text
        onName(text.isEmpty ? nil : text)
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

    @objc private func showLog() { onShowTranscriptLog() }
    @objc private func newConversation() { onNewConversation() }
}

/// The panel's scrolling content, top-down.
final class ChiefSettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}
