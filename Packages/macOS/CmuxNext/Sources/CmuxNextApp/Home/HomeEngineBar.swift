import AppKit
import Foundation

/// The Chief's engine over the Home transcript (Lawrence, 2026-10-05: see
/// and swap the model and harness between turns). It shows the harness,
/// model and effort the next turn uses and the last turn's stats from the
/// host's trace (which engine answered, latency, tool calls, cache hit
/// rate, cost), and its pickers write `<mux home>/optchat/engine.json`,
/// which optchat-chief reads at each turn start (engine.rs), so a change
/// applies from the next turn. The compactor fields of the file are kept.
@MainActor
final class HomeEngineBar: NSView {
    private let muxHome: URL
    private let harness = NSPopUpButton(frame: .zero, pullsDown: false)
    private let model = NSPopUpButton(frame: .zero, pullsDown: false)
    private let effort = NSPopUpButton(frame: .zero, pullsDown: false)
    private let stats = NSTextField(labelWithString: "")
    private let stack = NSStackView()

    static let harnesses = ["claude-sr", "codex"]
    static let models = ["claude-opus-5-5", "claude-sonnet-5-5", "gpt-6-sol"]
    static let efforts = ["low", "medium", "high", "xhigh"]

    init(muxHome: URL) {
        self.muxHome = muxHome
        super.init(frame: .zero)
        for (button, label) in [(harness, HomeEngineStrings.harness), (model, HomeEngineStrings.model), (effort, HomeEngineStrings.effort)] {
            button.controlSize = .small
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            button.toolTip = label
            button.target = self
            button.action = #selector(picked(_:))
        }
        stats.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        stats.textColor = .secondaryLabelColor
        stats.lineBreakMode = .byTruncatingTail
        stats.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        for view in [harness, model, effort, stats] { stack.addArrangedSubview(view) }
        addSubview(stack)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        stack.frame = bounds
    }

    private var engineFile: URL { muxHome.appendingPathComponent("optchat/engine.json") }
    private var traceDirectory: URL { muxHome.appendingPathComponent("optchat/traces", isDirectory: true) }

    private func readChoice() -> [String: Any] {
        guard let data = try? Data(contentsOf: engineFile),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    /// Re-reads the file and the trace (a new message or a turn's end).
    func refresh() {
        let choice = readChoice()
        fill(harness, Self.harnesses, current: choice["harness"] as? String)
        fill(model, Self.models, current: choice["model"] as? String)
        fill(effort, Self.efforts, current: choice["effort"] as? String)
        stats.stringValue = lastTurn().map(HomeEngineStrings.lastTurn) ?? HomeEngineStrings.noTurn
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
        var choice = readChoice()
        let key = sender === harness ? "harness" : sender === model ? "model" : "effort"
        if let value = sender.selectedItem?.representedObject as? String {
            choice[key] = value
        } else {
            choice.removeValue(forKey: key)
        }
        write(choice)
        refresh()
    }

    /// The same file optchat-chief writes: 0600, through a rename.
    private func write(_ choice: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: choice, options: [.prettyPrinted, .sortedKeys]) else { return }
        let directory = engineFile.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent("engine.json.app.tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data + Data("\n".utf8),
                                             attributes: [.posixPermissions: 0o600]) else { return }
        _ = try? FileManager.default.replaceItemAt(engineFile, withItemAt: temporary)
        if !FileManager.default.fileExists(atPath: engineFile.path) {
            try? FileManager.default.moveItem(at: temporary, to: engineFile)
        }
    }

    /// The trace's last `turn.end` (today's file, else yesterday's).
    private func lastTurn() -> HomeEngineTurn? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        for offset in [0, -1] {
            let day = formatter.string(from: Date().addingTimeInterval(Double(offset) * 86_400))
            let file = traceDirectory.appendingPathComponent("\(day).jsonl")
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n").reversed() where line.contains("\"turn.end\"") {
                if let turn = HomeEngineTurn(line: String(line)) { return turn }
            }
        }
        return nil
    }
}

/// One `turn.end` of the trace.
struct HomeEngineTurn: Equatable {
    var harness: String
    var model: String?
    var seconds: Double
    var tools: Int
    var toolErrors: Int
    var hitRate: Double?
    var cost: Double?

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
    static var harness: String { String(localized: "home.engine.harness", defaultValue: "Harness", table: "Home", bundle: .module) }
    static var model: String { String(localized: "home.engine.model", defaultValue: "Model", table: "Home", bundle: .module) }
    static var effort: String { String(localized: "home.engine.effort", defaultValue: "Effort", table: "Home", bundle: .module) }
    static var defaultValue: String { String(localized: "home.engine.default", defaultValue: "Default", table: "Home", bundle: .module) }
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
