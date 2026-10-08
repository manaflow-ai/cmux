import AppKit
import CmuxNextActions
import Foundation

/// The Chief's settings, a right sidebar inside the Home page that the
/// header's "Chief >" name pill toggles (Lawrence, 2026-10-05: per-Chief
/// configuration opens only from the pill). One per Chief: its settings
/// live in that Chief's mux home. The pickers write
/// `<mux home>/optchat/engine.json`, which optchat-chief reads at each turn
/// start (engine.rs), so a change applies from the next turn; the compactor
/// fields of the file are kept. It also shows the last turn's engine and
/// stats from the host's trace, where the brain runs, its tools, and opens
/// the trace folder.
@MainActor
final class HomeChiefSidebar: NSView {
    static let width: CGFloat = 280
    private let muxHome: URL
    private let harness = NSPopUpButton(frame: .zero, pullsDown: false)
    private let model = NSPopUpButton(frame: .zero, pullsDown: false)
    private let effort = NSPopUpButton(frame: .zero, pullsDown: false)
    private let stats = NSTextField(wrappingLabelWithString: "")
    private let replies = NSTextField(wrappingLabelWithString: "")
    private let nameField = NSTextField(string: "")
    private let avatarField = NSTextField(string: "")
    private let stack = NSStackView()
    /// Everything that reads or writes this Mac's brain (pickers, stats,
    /// replies, where it runs, traces, memory): hidden for a Chief whose
    /// brain runs on a paired server.
    private var localViews: [NSView] = []
    /// Said for a Chief placed on a paired server.
    private let elsewhere = NSTextField(wrappingLabelWithString: HomeEngineStrings.runsElsewhere)
    private var runsElsewhere = false
    /// Renames the Chief conversation (the daemon's set-title op).
    var onRename: (String) -> Void = { _ in }
    /// The header avatar's text changed (nil: the initials).
    var onAvatar: (String?) -> Void = { _ in }
    /// Show Memory: runs "Chief: Open Memory Inspector".
    var onShowMemory: () -> Void = {}

    static let harnesses = ["claude-sr", "codex"]
    static let models = ["claude-opus-5-5", "claude-sonnet-5-5", "gpt-6-sol"]
    static let efforts = ["low", "medium", "high", "xhigh"]

    init(muxHome: URL) {
        self.muxHome = muxHome
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.6).cgColor
        setAccessibilityRole(.group)
        setAccessibilityLabel(HomeEngineStrings.title)
        let title = NSTextField(labelWithString: HomeEngineStrings.title)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.addArrangedSubview(title)
        // Name and avatar of this Chief.
        for (field, label, action) in [(nameField, HomeEngineStrings.name, #selector(renamed)),
                                       (avatarField, HomeEngineStrings.avatar, #selector(avatarChanged))] {
            let caption = NSTextField(labelWithString: label)
            caption.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            caption.textColor = .secondaryLabelColor
            field.target = self
            field.action = action
            field.setAccessibilityLabel(label)
            field.placeholderString = label
            stack.addArrangedSubview(caption)
            stack.addArrangedSubview(field)
            field.widthAnchor.constraint(equalToConstant: Self.width - 32).isActive = true
        }
        for (button, label) in [(harness, HomeEngineStrings.harness), (model, HomeEngineStrings.model), (effort, HomeEngineStrings.effort)] {
            button.target = self
            button.action = #selector(picked(_:))
            button.setAccessibilityLabel(label)
            let caption = NSTextField(labelWithString: label)
            caption.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            caption.textColor = .secondaryLabelColor
            stack.addArrangedSubview(caption)
            stack.addArrangedSubview(button)
            button.widthAnchor.constraint(equalToConstant: Self.width - 32).isActive = true
            localViews += [caption, button]
        }
        let note = NSTextField(wrappingLabelWithString: HomeEngineStrings.nextTurn)
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        stack.addArrangedSubview(note)
        stats.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        stats.textColor = .secondaryLabelColor
        stack.addArrangedSubview(stats)
        replies.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        replies.textColor = .secondaryLabelColor
        stack.addArrangedSubview(replies)
        let brain = NSTextField(wrappingLabelWithString: String(format: HomeEngineStrings.brainFormat, muxHome.path))
        brain.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        brain.textColor = .secondaryLabelColor
        stack.addArrangedSubview(brain)
        let traces = NSButton(title: HomeEngineStrings.openTraces, target: self, action: #selector(openTraces))
        traces.bezelStyle = .push
        stack.addArrangedSubview(traces)
        // The memory inspector (DEV and nightly, like its palette action).
        if DevTools.isEnabled {
            let memory = NSButton(title: HomeEngineStrings.showMemory, target: self, action: #selector(showMemory))
            memory.bezelStyle = .push
            stack.addArrangedSubview(memory)
            localViews.append(memory)
        }
        localViews += [note, stats, replies, brain, traces]
        elsewhere.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        elsewhere.textColor = .secondaryLabelColor
        elsewhere.isHidden = true
        stack.addArrangedSubview(elsewhere)
        for view in [note, stats, replies, brain, elsewhere] {
            view.preferredMaxLayoutWidth = Self.width - 32
        }
        addSubview(stack)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        stack.frame = CGRect(x: 0, y: 0, width: Self.width, height: bounds.height)
    }

    /// Whether this Chief's brain runs on a paired server (a cloud Chief):
    /// its engine is set there, so this Mac's engine.json, trace and memory
    /// never show or change it. False: this Mac's brain (the default).
    func setRunsElsewhere(_ elsewhere: Bool) {
        guard elsewhere != runsElsewhere else { return }
        runsElsewhere = elsewhere
        for view in localViews { view.isHidden = elsewhere }
        self.elsewhere.isHidden = !elsewhere
        if !elsewhere { refresh() }
    }

    /// The conversation's title, shown in the name field.
    func setName(_ name: String) {
        if nameField.currentEditor() == nil { nameField.stringValue = name }
    }

    @objc private func renamed() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { onRename(name) }
    }

    /// The avatar text (at most 2 characters, an emoji counts as one), kept
    /// in `<mux home>/optchat/profile.json` beside this Chief's settings.
    @objc private func avatarChanged() {
        let text = String(avatarField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2))
        avatarField.stringValue = text
        let files = HomeChiefFiles(muxHome: muxHome)
        // task-owner: one file write off the main actor; ends with it
        Task.detached { files.writeAvatar(text) }
        onAvatar(text.isEmpty ? nil : text)
    }

    @objc private func showMemory() {
        onShowMemory()
    }

    @objc private func openTraces() {
        NSWorkspace.shared.activateFileViewerSelecting([HomeChiefFiles(muxHome: muxHome).traceDirectory])
    }

    /// Re-reads the engine file and the trace (a new message or a turn's
    /// end) off the main actor, then shows them.
    func refresh() {
        guard !runsElsewhere else { return }
        let files = HomeChiefFiles(muxHome: muxHome)
        // task-owner: one read off the main actor; ends when it is shown
        Task { [weak self] in
            let snapshot = await Task.detached { files.snapshot() }.value
            self?.show(snapshot)
        }
    }

    private func show(_ snapshot: HomeChiefSnapshot) {
        fill(harness, Self.harnesses, current: snapshot.harness)
        fill(model, Self.models, current: snapshot.model)
        fill(effort, Self.efforts, current: snapshot.effort)
        if avatarField.currentEditor() == nil { avatarField.stringValue = snapshot.avatar ?? "" }
        stats.stringValue = snapshot.turns.first.map(HomeEngineStrings.lastTurn) ?? HomeEngineStrings.noTurn
        // Which engine answered each recent reply (the trace's turn.end).
        replies.stringValue = snapshot.turns.isEmpty ? ""
            : HomeEngineStrings.answeredBy + "\n" + snapshot.turns.map(HomeEngineStrings.reply).joined(separator: "\n")
    }

    /// `values` with a "default" first and the current value kept even
    /// when it is not one of them.
    private func fill(_ button: NSPopUpButton, _ values: [String], current: String?) {
        button.removeAllItems()
        button.addItem(withTitle: HomeEngineStrings.defaultValue)
        button.lastItem?.representedObject = nil
        var all = values
        if let current, !all.contains(current) { all.append(current) }
        for value in all {
            button.addItem(withTitle: value)
            button.lastItem?.representedObject = value
        }
        if let current, let index = all.firstIndex(of: current) {
            button.selectItem(at: index + 1)
        } else {
            button.selectItem(at: 0)
        }
    }

    @objc private func picked(_ sender: NSPopUpButton) {
        guard !runsElsewhere else { return }
        let key = sender === harness ? "harness" : sender === model ? "model" : "effort"
        let value = sender.selectedItem?.representedObject as? String
        let files = HomeChiefFiles(muxHome: muxHome)
        // task-owner: one read-modify-write off the main actor, then a refresh
        Task { [weak self] in
            await Task.detached { files.setEngine(key, value) }.value
            self?.refresh()
        }
    }
}
