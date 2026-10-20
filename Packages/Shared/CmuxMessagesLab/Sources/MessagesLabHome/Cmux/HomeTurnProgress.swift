import Foundation

/// How the Chief's running indicator (the status line above its typing dots) reads while a turn runs.
///
/// Leo 2026-10-20: "Using optchat: control · 6m 3s" with the typing dots for six minutes said nothing.
/// The agent chat shows its progress narration and folds its tool calls ("Ran 3 commands ›"); Home
/// keeps its compact column of short caption rows and shows the same, at most three rows.
public enum HomeTurnProgressStyle: String, Sendable, CaseIterable {
    /// The default: the turn's finished steps folded into one row, the Chief's newest thought as a
    /// narration row, then the step running now with its time.
    case narrated
    /// The folded steps and the step running now, without the thought row.
    case steps
    /// The one line from before: the step running now and its time.
    case line
}

/// The rows of the running indicator for one turn, newest last: pure, so tests read it directly.
struct HomeTurnProgress: Equatable {
    /// The folded row of the finished steps ("Ran 3 commands · Telling a31 ›"), nil before one finished.
    var summary: String?
    /// The Chief's progress narration: its newest thought's headline, nil when there is none to show.
    var narration: String?
    /// The step running now and its time so far ("Checking on a31 · 2m 10s").
    var current: String

    /// The rows top to bottom.
    var rows: [String] { [summary, narration, current].compactMap { $0 } }

    /// The status line's text: one row per line (`HomeNoticeRows` draws each in its own row).
    var text: String { rows.joined(separator: "\n") }

    /// Lines the owner sends for its own writing, not a step of the turn's work.
    static let notSteps: Set<String> = ["Thinking", "Writing the reply", "Working"]
    /// Most characters a narration row keeps.
    static let narrationLimit = 72

    init(summary: String?, narration: String?, current: String) {
        self.summary = summary
        self.narration = narration
        self.current = current
    }

    /// The indicator for `steps` (the turn so far, the running one last), the newest `thought`, at `now`.
    init(steps: [HomeTurnSteps.Step], current activity: HomeLiveActivity, thought: String?, now: Date,
         style: HomeTurnProgressStyle) {
        let line = HomeLiveLine.text(activity, now: now)
        guard style != .line else {
            self.init(summary: nil, narration: nil, current: line)
            return
        }
        let finished = steps.filter { $0.end != nil }.map(\.line).filter { !Self.notSteps.contains($0) }
        let summary = Self.summary(finished)
        var narration = style == .narrated ? thought.flatMap(Self.headline) : nil
        var current = line
        if let told = narration, activity.line == "Thinking" {
            // Thinking now: its headline is the running row, not a second row over "Thinking".
            current = HomeLiveLine.elapsed(now.timeIntervalSince(activity.since)).map { "\(told) · \($0)" } ?? told
            narration = nil
        } else if narration == activity.line {
            narration = nil
        }
        self.init(summary: summary, narration: narration, current: current)
    }

    // MARK: Folding

    /// What a finished step did, by the verb the owner's line starts with (optchat-chief's
    /// `activity_line`: "Running git log -1", "Reading notes.md", "Editing app.ts", "Searching").
    enum Kind: Equatable {
        case commands, reads, edits, searches, other
    }

    static func kind(_ line: String) -> Kind {
        if line.hasPrefix("Running ") { return .commands }
        // "Reading the chat history" and "Reading the Chief's profile" are the Chief's own tools, not files.
        if line.hasPrefix("Reading "), !line.hasPrefix("Reading the ") { return .reads }
        if line.hasPrefix("Editing ") || line.hasPrefix("Deleting ") || line.hasPrefix("Moving ") { return .edits }
        if line.hasPrefix("Searching") { return .searches }
        return .other
    }

    /// The finished steps in one row: each kind with two or more steps by its fold label (the agent
    /// chat's words: "Ran 3 commands", "Read 2 files"), in the order the turn first did it; a single
    /// other step by its own line, several as "N steps" ("N more steps" after a fold); then "›",
    /// since a click on the line lists every step. Nil before any step finished.
    static func summary(_ finished: [String]) -> String? {
        guard !finished.isEmpty else { return nil }
        var order: [Kind] = []
        var counts: [Kind: Int] = [:]
        for line in finished {
            let kind = kind(line)
            if counts[kind] == nil { order.append(kind) }
            counts[kind, default: 0] += 1
        }
        var parts: [String] = []
        var rest: [String] = []
        for kind in order {
            let count = counts[kind] ?? 0
            if kind != .other, count >= 2, let label = foldLabel(kind, count) {
                parts.append(label)
            } else {
                rest += finished.filter { Self.kind($0) == kind }
            }
        }
        if rest.count == 1, let only = rest.first {
            parts.append(only)
        } else if rest.count > 1 {
            parts.append(parts.isEmpty ? CmuxStrings.turnSteps(rest.count) : CmuxStrings.turnMoreSteps(rest.count))
        }
        return parts.joined(separator: " · ") + " ›"
    }

    static func foldLabel(_ kind: Kind, _ count: Int) -> String? {
        switch kind {
        case .commands: CmuxStrings.turnRanCommands(count)
        case .reads: CmuxStrings.turnReadFiles(count)
        case .edits: CmuxStrings.turnEditedFiles(count)
        case .searches: CmuxStrings.turnRanSearches(count)
        case .other: nil
        }
    }

    // MARK: Narration

    /// A thought's headline: its last bold heading line ("**Checking the tests**", how Claude and
    /// Codex title their reasoning summaries), else its last sentence, as plain text of at most
    /// ``narrationLimit`` characters. Nil for a thought with no words.
    static func headline(_ thought: String) -> String? {
        let lines = thought.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let heading = lines.last { $0.count > 4 && $0.hasPrefix("**") && $0.hasSuffix("**") }
        let raw: String
        if let heading {
            raw = String(heading.dropFirst(2).dropLast(2))
        } else if let last = lines.last {
            raw = lastSentence(last)
        } else {
            return nil
        }
        let plain = raw.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "*_#> ").union(.whitespaces))
        guard !plain.isEmpty else { return nil }
        guard plain.count > narrationLimit else { return plain }
        return String(plain.prefix(narrationLimit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The last sentence of `line` (after its last ". ", "! " or "? "), or the line.
    static func lastSentence(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let body = trimmed.last.map { ".!?".contains($0) } == true ? String(trimmed.dropLast()) : trimmed
        var start = body.startIndex
        for end in [". ", "! ", "? "] {
            if let range = body.range(of: end, options: .backwards), range.upperBound > start { start = range.upperBound }
        }
        let sentence = body[start...].trimmingCharacters(in: .whitespaces)
        return sentence.isEmpty ? trimmed : sentence
    }
}
