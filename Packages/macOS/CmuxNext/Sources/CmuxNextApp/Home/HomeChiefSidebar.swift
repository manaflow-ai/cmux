import AppKit
import CmuxNextActions
import Foundation

/// The Chief's settings, a right sidebar inside the Home page that the
/// header's "Chief >" name pill toggles (Lawrence, 2026-10-05: per-Chief
/// configuration opens only from the pill). One per Chief: the pickers read
/// and write the engine of the brain that answers it (`HomeChiefEngineSource`):
/// this Mac's `<mux home>/optchat/engine.json`, or a paired server's brain
/// through `chief.engine.get` / `chief.engine.set` for a cloud Chief.
/// optchat-chief reads it at each turn start (engine.rs), so a change
/// applies from the next turn. It also shows the last turns' engines and
/// stats, where the brain runs, and (this Mac's brain only) its traces.
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
    /// This Mac's brain only (its mux home, traces, memory): hidden for a
    /// Chief whose brain runs on a paired server.
    private var localViews: [NSView] = []
    /// Where a paired server's brain runs.
    private let place = NSTextField(wrappingLabelWithString: "")
    /// Why the engine could not be read or set.
    private let failure = NSTextField(wrappingLabelWithString: "")
    private var source: any HomeChiefEngineSource
    /// Renames the Chief conversation (the daemon's set-title op).
    var onRename: (String) -> Void = { _ in }
    /// The header avatar's text changed (nil: the initials).
    var onAvatar: (String?) -> Void = { _ in }
    /// Show Memory: runs "Chief: Open Memory Inspector".
    var onShowMemory: () -> Void = {}

    /// The harness items the picker offers: the user's own Claude login and
    /// Codex; the CodeRouter route (`claude-cr`) only when this Chief's
    /// acpmux has one configured. The subrouter pool (`claude-sr`) is never a
    /// default item; a current choice of it still shows (`fill`).
    static func harnesses(routeConfigured: Bool) -> [String] {
        routeConfigured ? ["claude", "claude-cr", "codex"] : ["claude", "codex"]
    }
    static let models = ["claude-opus-5-5", "claude-sonnet-5-5", "gpt-6-sol"]
    static let efforts = ["low", "medium", "high", "xhigh"]

    init(muxHome: URL, source: any HomeChiefEngineSource) {
        self.muxHome = muxHome
        self.source = source
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
        localViews += [brain, traces]
        place.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        place.textColor = .secondaryLabelColor
        place.isHidden = true
        stack.insertArrangedSubview(place, at: stack.arrangedSubviews.firstIndex(of: brain) ?? 0)
        failure.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        failure.textColor = .systemRed
        failure.isHidden = true
        stack.insertArrangedSubview(failure, at: stack.arrangedSubviews.firstIndex(of: note) ?? 0)
        for view in [note, stats, replies, brain, place, failure] {
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

    /// The brain this panel shows and sets: this Mac's (the default) or a
    /// paired server's (a cloud Chief), then a read of it.
    @discardableResult
    func use(_ source: any HomeChiefEngineSource) -> Task<Void, Never> {
        self.source = source
        for view in localViews { view.isHidden = !source.isLocal }
        place.isHidden = source.isLocal
        place.stringValue = source.place.map { String(format: HomeEngineStrings.runsOnServerFormat, $0) } ?? ""
        return refresh()
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

    /// Re-reads the engine and the last turns (a new message or a turn's
    /// end) off the main actor, then shows them, or why it could not.
    @discardableResult
    func refresh() -> Task<Void, Never> {
        let source = source
        // task-owner: one read off the main actor; ends when it is shown
        return Task { [weak self] in
            let result = await Task.detached { () async -> Result<HomeChiefSnapshot, HomeChiefEngineError> in
                do { return .success(try await source.read()) } catch let error as HomeChiefEngineError { return .failure(error) } catch { return .failure(.other(String(describing: error))) }
            }.value
            guard let self, self.source.isLocal == source.isLocal, self.source.place == source.place else { return }
            switch result {
            case .success(let snapshot): show(snapshot)
            case .failure(let error): say(error, readable: false)
            }
        }
    }

    /// Sets (nil: clears) one engine field on the brain, then shows the result.
    @discardableResult
    func pick(_ key: String, _ value: String?) -> Task<Void, Never> {
        let source = source
        // task-owner: one write off the main actor; ends when its result is shown
        return Task { [weak self] in
            let result = await Task.detached { () async -> Result<HomeChiefSnapshot, HomeChiefEngineError> in
                do { return .success(try await source.set(key, value)) } catch let error as HomeChiefEngineError { return .failure(error) } catch { return .failure(.other(String(describing: error))) }
            }.value
            switch result {
            case .success(let snapshot): self?.show(snapshot)
            case .failure(let error): self?.say(error, readable: true)
            }
        }
    }

    /// Says `error`; the pickers stay usable only when the brain answered before.
    private func say(_ error: HomeChiefEngineError, readable: Bool) {
        failure.stringValue = error.text
        failure.isHidden = false
        if !readable { for button in [harness, model, effort] { button.isEnabled = false } }
    }

    private func show(_ snapshot: HomeChiefSnapshot) {
        failure.isHidden = true
        for button in [harness, model, effort] { button.isEnabled = true }
        fill(harness, Self.harnesses(routeConfigured: snapshot.routeConfigured), current: snapshot.harness)
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
        let key = sender === harness ? "harness" : sender === model ? "model" : "effort"
        pick(key, sender.selectedItem?.representedObject as? String)
    }
}
