import AppKit
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
    /// Renames the Chief conversation (the daemon's set-title op).
    var onRename: (String) -> Void = { _ in }
    /// The header avatar's text changed (nil: the initials).
    var onAvatar: (String?) -> Void = { _ in }

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
        for view in [note, stats, replies, brain] {
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

    @objc private func openTraces() {
        NSWorkspace.shared.activateFileViewerSelecting([HomeChiefFiles(muxHome: muxHome).traceDirectory])
    }

    /// Re-reads the engine file and the trace (a new message or a turn's
    /// end) off the main actor, then shows them.
    func refresh() {
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

/// What the sidebar shows, read from this Chief's files.
struct HomeChiefSnapshot: Sendable {
    var harness: String?
    var model: String?
    var effort: String?
    var avatar: String?
    /// The trace's last `turn.end`s, newest first.
    var turns: [HomeEngineTurn]
}

/// This Chief's files under its mux home: `optchat/engine.json` (the engine
/// optchat-chief reads at each turn start), `optchat/profile.json` (the
/// avatar) and `optchat/traces/` (read only). Blocking file I/O, so it runs
/// off the main actor.
nonisolated struct HomeChiefFiles: Sendable {
    let muxHome: URL
    var engineFile: URL { muxHome.appendingPathComponent("optchat/engine.json") }
    var profileFile: URL { muxHome.appendingPathComponent("optchat/profile.json") }
    var traceDirectory: URL { muxHome.appendingPathComponent("optchat/traces", isDirectory: true) }

    private func object(_ file: URL) -> [String: Any] {
        // concurrency-allow: HomeChiefFiles runs only inside Task.detached, never on the main actor
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    func snapshot() -> HomeChiefSnapshot {
        let choice = object(engineFile)
        let avatar = (object(profileFile)["avatar"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return HomeChiefSnapshot(harness: choice["harness"] as? String, model: choice["model"] as? String,
                                 effort: choice["effort"] as? String, avatar: avatar, turns: recentTurns(limit: 5))
    }

    /// The avatar alone (the header reads it when Home opens).
    func avatar() -> String? { snapshot().avatar }

    /// Sets (or with nil clears) one engine field; the compactor fields stay.
    func setEngine(_ key: String, _ value: String?) {
        var choice = object(engineFile)
        if let value { choice[key] = value } else { choice.removeValue(forKey: key) }
        write(choice, to: engineFile)
    }

    func writeAvatar(_ text: String) {
        var profile = object(profileFile)
        if text.isEmpty { profile.removeValue(forKey: "avatar") } else { profile["avatar"] = text }
        write(profile, to: profileFile)
    }

    /// 0600, through a temporary file and a replace, as optchat-chief writes.
    private func write(_ object: [String: Any], to file: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return }
        let directory = file.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(file.lastPathComponent + ".app.tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data + Data("\n".utf8),
                                             attributes: [.posixPermissions: 0o600]) else { return }
        if FileManager.default.fileExists(atPath: file.path) {
            _ = try? FileManager.default.replaceItemAt(file, withItemAt: temporary)
        } else {
            try? FileManager.default.moveItem(at: temporary, to: file)
        }
    }

    /// The trace's last `turn.end`s, newest first (today's file, then yesterday's).
    func recentTurns(limit: Int) -> [HomeEngineTurn] {
        var found: [HomeEngineTurn] = []
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        for offset in [0, -1] {
            let day = formatter.string(from: Date().addingTimeInterval(Double(offset) * 86_400))
            let file = traceDirectory.appendingPathComponent("\(day).jsonl")
            // concurrency-allow: HomeChiefFiles runs only inside Task.detached, never on the main actor
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n").reversed() where line.contains("\"turn.end\"") {
                if let turn = HomeEngineTurn(line: String(line)) { found.append(turn) }
                if found.count >= limit { return found }
            }
        }
        return found
    }
}

/// One `turn.end` of the trace.
nonisolated struct HomeEngineTurn: Equatable, Sendable {
    var harness: String
    var model: String?
    var seconds: Double
    var tools: Int
    var toolErrors: Int
    var hitRate: Double?
    var cost: Double?
    /// The reply's first characters (the trace keeps no more).
    var reply: String?

    init?(line: String) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["ev"] as? String == "turn.end" else { return nil }
        harness = object["harness"] as? String ?? "?"
        model = object["model"] as? String
        seconds = (object["ms"] as? Double ?? 0) / 1000
        tools = object["tools"] as? Int ?? 0
        toolErrors = object["tool_errors"] as? Int ?? 0
        cost = object["cost_usd"] as? Double
        reply = (object["reply"] as? [String: Any])?["prefix"] as? String
        if let usage = object["usage"] as? [String: Any] {
            let read = usage["cache_read"] as? Double ?? 0
            let total = read + (usage["cache_write"] as? Double ?? 0) + (usage["input"] as? Double ?? 0)
            hitRate = total > 0 ? read / total : nil
        } else {
            hitRate = nil
        }
    }
}

nonisolated enum HomeEngineStrings {
    static var title: String { String(localized: "home.engine.title", defaultValue: "Chief Settings", table: "Home", bundle: .module) }
    static var pillHelp: String { String(localized: "home.engine.pillHelp", defaultValue: "Shows or hides this Chief's settings", table: "Home", bundle: .module) }
    static var nextTurn: String { String(localized: "home.engine.nextTurn", defaultValue: "Changes apply from the next turn.", table: "Home", bundle: .module) }
    static var openTraces: String { String(localized: "home.engine.openTraces", defaultValue: "Show Traces", table: "Home", bundle: .module) }
    static var brainFormat: String {
        String(localized: "home.engine.brain", defaultValue: "Runs on this Mac (%@). Tools: zoom, date, spawn, tell and the harness's own.", table: "Home", bundle: .module)
    }
    static var harness: String { String(localized: "home.engine.harness", defaultValue: "Harness", table: "Home", bundle: .module) }
    static var model: String { String(localized: "home.engine.model", defaultValue: "Model", table: "Home", bundle: .module) }
    static var effort: String { String(localized: "home.engine.effort", defaultValue: "Effort", table: "Home", bundle: .module) }
    static var defaultValue: String { String(localized: "home.engine.default", defaultValue: "Default", table: "Home", bundle: .module) }
    static var name: String { String(localized: "home.engine.name", defaultValue: "Name", table: "Home", bundle: .module) }
    static var avatar: String { String(localized: "home.engine.avatar", defaultValue: "Avatar", table: "Home", bundle: .module) }
    static var answeredBy: String { String(localized: "home.engine.answeredBy", defaultValue: "Recent replies, answered by:", table: "Home", bundle: .module) }

    /// "“Both subagents are done…” claude-sr, claude-opus-5-5".
    static func reply(_ turn: HomeEngineTurn) -> String {
        let engine = [turn.harness, turn.model].compactMap { $0 }.joined(separator: ", ")
        return "\u{201C}\(turn.reply ?? "")\u{201D} \(engine)"
    }

    static var noTurn: String { String(localized: "home.engine.noTurn", defaultValue: "No turn yet", table: "Home", bundle: .module) }

    /// "Last turn: claude-sr, claude-opus-5-5, 7.8 s, 1 tool call, 50% cached, $0.144".
    static func lastTurn(_ turn: HomeEngineTurn) -> String {
        let engine = [turn.harness, turn.model].compactMap { $0 }.joined(separator: ", ")
        let hit = turn.hitRate.map { "\(Int(($0 * 100).rounded()))%" } ?? "-"
        let cost = turn.cost.map { String(format: "$%.3f", $0) } ?? "-"
        let format = String(localized: "home.engine.lastTurn",
                            defaultValue: "Last turn: %1$@, %2$@ s, %3$lld tool calls (%4$lld failed), %5$@ cached, %6$@",
                            table: "Home", bundle: .module)
        return String(format: format, engine, String(format: "%.1f", turn.seconds), turn.tools, turn.toolErrors, hit, cost)
    }
}
