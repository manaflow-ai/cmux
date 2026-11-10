import CmuxAgentQuestion
import CmuxMobileDiff
import CmuxMobileMarkdown
import Foundation

/// One cell of the agent chat transcript: the session line, a prompt bubble, one block
/// of an answer, a tool row, a card, or a turn's footer. A long answer is one row per
/// markdown block, so a streamed token changes the last block's row only.
struct ChatRow: Equatable, Identifiable, Sendable {
    /// Stable for the life of the row (`TurnRow.id`, plus `#<block>` for answer blocks).
    var id: String
    var turnID: String
    var kind: Kind
    /// Space above the row, in points (the old turn layout's stack spacing).
    var gap: Double

    enum Kind: Equatable, Sendable {
        /// `earlier`: the chat opened on its newest history (older records exist), so the line
        /// says where what is shown starts instead of when the session started.
        case sessionStart(Date, earlier: Bool)
        case prompt(text: String, attachments: [AgentAttachment], at: Date, isLast: Bool)
        /// The turn's prompt is another agent's message: its card (AgentIncomingCard), not the person's
        /// bubble, with the images and files the prompt carried.
        case incoming(AgentIncoming, attachments: [AgentAttachment], at: Date)
        /// A message steered into the running turn, where it went in: the person's bubble, or
        /// another agent's card (`incoming`). It takes none of the turn prompt's edit actions.
        case steer(SteeredMessage)
        /// One block of the agent message `messageID` (the whole message is copied).
        case block(messageID: String, block: MarkdownBlock)
        case thought(text: String, isLive: Bool)
        case tool(ACPToolCall)
        case toolGroup([ACPToolCall], turnRunning: Bool)
        /// A finished edit's snippet; `files` is nil while its diff computes.
        case edit(ACPToolCall, files: [ChatDiffCache.EditPreview]?)
        case plan([ACPPlanEntry])
        /// `offersChoices`: the composer took the bar's place ("Reply instead"); the card
        /// brings the choices back.
        case permission(PermissionRecord, offersChoices: Bool)
        case question(AgentQuestion)
        case subagents([String])
        case working(label: String, since: Date?)
        case editedFiles(DiffChangeSet)
        case stopped
        case failed(prompt: String, errorText: String?)
        case actions(AgentTurn, isLast: Bool)
        /// The tagged ask a finished turn's answer ended on (the Mac's next-step card):
        /// `answer` once a prompt followed it (the card folds), `canAnswer` while its buttons send.
        case nextStep(NextStepAsk, answer: String?, canAnswer: Bool)
        /// An acpmux "who else is working on these files" call (`toolCallID`) as its card
        /// (`WhoElseCard`), in place of the tool row.
        case whoElse(String, WhoElseCall)
    }

    /// The session line's text: "Session started …", or "Showing messages since …" when
    /// the chat opened on its newest history.
    static func sessionLine(_ date: Date, earlier: Bool) -> String {
        let when = date.formatted(date: .abbreviated, time: .shortened)
        return earlier ? "Showing messages since \(when)" : "Session started \(when)"
    }

    /// The answer action row draws 6 pt into the gaps around it (its 44 pt targets).
    var isActions: Bool {
        if case .actions = kind { return true }
        return false
    }
}

/// Everything a turn's rows depend on besides the turn itself.
struct ChatTurnContext: Equatable, Sendable {
    var isFirst: Bool
    var isLast: Bool
    /// The first turn of a chat opened on its newest history (`sessionStart(earlier:)`).
    var earlierHistory = false
    /// The previous turn ended on its action row (the bubble's gap is 6 pt less).
    var followsActions: Bool
    /// A permission or question waits on the person (the working label hides).
    var askOpen: Bool
    /// The permission whose card offers the choices (the bar is out of the composer's place).
    var choicesFor: String?
    /// The next turn's prompt: a next-step card this turn ended on folds to the answer it gave.
    var nextPrompt: String?
    /// The tones the chat gave this turn's senders' sessions (`AgentTones`), by session id.
    var senderTones: [String: Int] = [:]
}

/// A turn's rows, built once per change to the turn.
struct ChatTurnRows: Sendable {
    var turnID: String
    var rows: [ChatRow]
    /// A new value for every build: equal generations are the same rows.
    var generation: Int
}

/// Builds the transcript's rows from the store's turns, keeping each turn's rows until
/// the turn (or what its rows depend on) changes, and each answer's parse until its text
/// grows (then only its tail is parsed again). A streamed token rebuilds the last turn
/// and re-parses one or two blocks; every other turn is a comparison.
@MainActor
final class ChatTranscriptBuilder {
    private struct Memo {
        var turn: AgentTurn
        var context: ChatTurnContext
        var rows: ChatTurnRows
        /// Built while a diff it shows was computing: built again when one lands.
        var waitsForDiff: Bool
        var diffVersion: Int
    }

    let diffs: ChatDiffCache
    private var memos: [String: Memo] = [:]
    private var parses: [String: MarkdownStreamParse] = [:]
    private var generation = 0
    /// The chat's senders' tones: each session that sent a message, from when the chat first heard
    /// from it (`AgentTones`, as the Mac tones a chat's agents).
    private var tones = AgentTones()
    private var senderFirstSeen: [String: Double] = [:]
    private var senderTones: [String: Int] = [:]
    /// Turns built (tests: one per changed turn, not one per turn per update).
    private(set) var turnBuilds = 0

    init(diffs: ChatDiffCache) {
        self.diffs = diffs
    }

    /// Lines the last parse of `messageID` read (tests: a token re-parses the tail only).
    func lastParsedLines(_ messageID: String) -> Int? { parses[messageID]?.lastParsedLines }

    func build(turns: [AgentTurn], pendingPermission: PermissionRecord?, askOpen: Bool, permissionBarHidden: Bool,
               earlierHistory: Bool = false) -> [ChatTurnRows] {
        var out: [ChatTurnRows] = []
        out.reserveCapacity(turns.count)
        var followsActions = false
        let choicesFor = permissionBarHidden ? pendingPermission?.request.id : nil
        assignSenderTones(turns)
        for (index, turn) in turns.enumerated() {
            let isLast = index == turns.count - 1
            let context = ChatTurnContext(isFirst: index == 0, isLast: isLast, earlierHistory: index == 0 && earlierHistory,
                                          followsActions: followsActions, askOpen: isLast && askOpen,
                                          choicesFor: isLast ? choicesFor : nil,
                                          nextPrompt: isLast ? nil : Self.reply(turns[index + 1].prompt),
                                          senderTones: turnTones(turn))
            let rows: ChatTurnRows
            if let memo = memos[turn.id], memo.context == context, memo.turn == turn,
               !memo.waitsForDiff || memo.diffVersion == diffs.version {
                rows = memo.rows
            } else {
                let built = buildTurn(turn, context: context)
                generation += 1
                turnBuilds += 1
                rows = ChatTurnRows(turnID: turn.id, rows: built.rows, generation: generation)
                memos[turn.id] = Memo(turn: turn, context: context, rows: rows, waitsForDiff: built.waitsForDiff, diffVersion: diffs.version)
            }
            followsActions = rows.rows.last?.isActions ?? false
            out.append(rows)
        }
        if memos.count > turns.count + 8 {
            let live = Set(turns.map(\.id))
            memos = memos.filter { live.contains($0.key) }
        }
        return out
    }

    /// A prompt that answers a card: nil when it is blank (a turn a notice or another agent
    /// started), so an earlier ask stays in its answer's text, as on the Mac.
    static func reply(_ prompt: String) -> String? {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : prompt
    }

    /// The space after the last row (the old transcript's padding under its last turn).
    static func trailingGap(after last: ChatRow?) -> Double {
        last?.isActions == true ? 18 : 24
    }

    /// `incoming` with each message's assigned tone.
    private static func toned(_ incoming: AgentIncoming, _ tones: [String: Int]) -> AgentIncoming {
        guard !tones.isEmpty else { return incoming }
        var toned = incoming
        for index in toned.messages.indices {
            toned.messages[index].tone = toned.messages[index].senderID.flatMap { tones[$0] }
        }
        return toned
    }

    /// Records the sessions that first sent a message in `turns` and, when there is a new one, assigns
    /// the chat's tones again. One look at each turn's senders, as the memo pass looks at each turn.
    private func assignSenderTones(_ turns: [AgentTurn]) {
        var added = false
        for turn in turns {
            for message in Self.incomingMessages(turn) {
                guard let id = message.senderID, senderFirstSeen[id] == nil else { continue }
                senderFirstSeen[id] = turn.promptAt.timeIntervalSince1970
                added = true
            }
        }
        guard added else { return }
        senderTones = tones.assign(senderFirstSeen.map { AgentTones.Agent(id: $0.key, startedAt: $0.value) })
    }

    /// Other agents' messages in `turn`: its prompt's card, then the cards steered into it.
    private static func incomingMessages(_ turn: AgentTurn) -> [AgentIncoming.Message] {
        var out = turn.incoming?.messages ?? []
        for case .steer(let steered) in turn.items {
            out += steered.incoming?.messages ?? []
        }
        return out
    }

    private func turnTones(_ turn: AgentTurn) -> [String: Int] {
        var out: [String: Int] = [:]
        for message in Self.incomingMessages(turn) {
            if let id = message.senderID, let tone = senderTones[id] { out[id] = tone }
        }
        return out
    }

    private func buildTurn(_ turn: AgentTurn, context: ChatTurnContext) -> (rows: [ChatRow], waitsForDiff: Bool) {
        var rows: [ChatRow] = []
        var waits = false
        let turnID = turn.id
        var nextGap = 16.0
        func add(_ id: String, _ kind: ChatRow.Kind, gap: Double? = nil) {
            rows.append(ChatRow(id: id, turnID: turnID, kind: kind, gap: gap ?? nextGap))
            nextGap = 10
        }
        if context.isFirst {
            rows.append(ChatRow(id: "session-start", turnID: turnID, kind: .sessionStart(turn.promptAt, earlier: context.earlierHistory), gap: 0))
        }
        // An inbox notice with nothing to show (AgentIncoming with no messages) draws no prompt row.
        if turn.incoming?.messages.isEmpty != true {
            rows.append(ChatRow(id: "u-\(turnID)", turnID: turnID,
                                kind: turn.incoming.map { .incoming(Self.toned($0, context.senderTones), attachments: turn.attachments, at: turn.promptAt) }
                                    ?? .prompt(text: turn.prompt, attachments: turn.attachments, at: turn.promptAt, isLast: context.isLast),
                                gap: context.isFirst ? 0 : (context.followsActions ? 18 : 24)))
        }
        let turnRows = turn.rows
        let running = turn.status == .running
        // The agent's own wrap-up call (WrapUp.swift) is the card, not a row of its work, and goes
        // before a tagged ask in its prose. Where nothing can answer it, it keeps its recap alone.
        let wrote = turn.status == .completed ? NextStepAsk.lastWrapUp(turnRows) : nil
        var wrapUp = wrote
        if let ask = wrapUp, !ask.question.isEmpty, !context.isLast, context.nextPrompt == nil {
            wrapUp = ask.recap != nil || ask.tryIt != nil
                ? NextStepAsk(tag: ask.tag, recap: ask.recap, question: "", detail: nil, options: [], rest: "", tryIt: ask.tryIt) : nil
        }
        // A finished turn's answer that ends on one tagged ask: the ask draws as a card under it.
        var nextStep: (rowID: String, ask: NextStepAsk)?
        // An earlier turn's card shows only with the reply that answered it (the Mac's rule).
        if wrote == nil, turn.status == .completed, context.isLast || context.nextPrompt != nil,
           let index = turnRows.lastIndex(where: { if case .message = $0 { true } else { false } }),
           case .message(_, let markdown) = turnRows[index], let ask = NextStepAsk.parse(markdown) {
            nextStep = (turnRows[index].id, ask)
        }
        for (index, row) in turnRows.enumerated() {
            let isLastRow = index == turnRows.count - 1
            switch row {
            case .message(let messageID, let markdown):
                let ask = nextStep?.rowID == row.id ? nextStep?.ask : nil
                // The answer without the ask's lines parses on its own key (its text is no prefix of the stream's).
                let key = ask == nil ? row.id : "\(row.id)#next"
                var parse = parses[key] ?? MarkdownStreamParse()
                parse.update(ask?.rest ?? markdown, isStreaming: running && isLastRow)
                parses[key] = parse
                for (blockIndex, block) in parse.displayed.enumerated() {
                    add("\(row.id)#\(block.id)", .block(messageID: messageID, block: block), gap: blockIndex == 0 ? nil : 12)
                }
                if let ask {
                    let answer = context.nextPrompt.map { ask.chosenAnswer($0) }
                    add("n-\(row.id)", .nextStep(ask, answer: answer, canAnswer: answer == nil && context.isLast))
                }
            case .thought(_, let text):
                add(row.id, .thought(text: text, isLive: running && isLastRow))
            case .tool(let call):
                if let whoElse = WhoElseCall(call) {
                    add(row.id, .whoElse(call.id, whoElse))
                } else if wrapUp == nil || !NextStepAsk.drawsWrapUp(call) {
                    // A wrap-up call's row goes only where its card draws in its place.
                    add(row.id, .tool(call))
                }
            case .toolGroup(_, let calls):
                let shown = wrapUp == nil ? calls : calls.filter { !NextStepAsk.drawsWrapUp($0) }
                if !shown.isEmpty { add(row.id, .toolGroup(shown, turnRunning: running)) }
            case .edit(let call):
                if call.isRunning {
                    add(row.id, .edit(call, files: nil))
                } else {
                    let files = diffs.files(for: call)
                    if files == nil { waits = true }
                    add(row.id, .edit(call, files: files))
                }
            case .plan(_, let entries):
                add(row.id, .plan(entries))
            case .permission(let record):
                add(row.id, .permission(record, offersChoices: record.request.id == context.choicesFor))
            case .question(let id):
                if let question = turn.question(id) { add(row.id, .question(question)) }
            case .subagents(_, let ids):
                add(row.id, .subagents(ids))
            case .steer(var message):
                message.incoming = message.incoming.map { Self.toned($0, context.senderTones) }
                add(row.id, .steer(message))
            }
        }
        if let wrapUp {
            let answer = wrapUp.question.isEmpty ? nil : context.nextPrompt.map { wrapUp.chosenAnswer($0) }
            add("n-\(turnID)", .nextStep(wrapUp, answer: answer, canAnswer: answer == nil && context.isLast))
        }
        if running, turnRows.needsWorkingIndicator, !context.askOpen {
            add("w-\(turnID)", .working(label: turn.retry?.label ?? "Working", since: turn.startedAt))
        }
        if !running {
            switch diffs.changeSet(for: turn) {
            case .some(.some(let changes)):
                // The card's 4 pt top padding.
                add("f-\(turnID)", .editedFiles(changes), gap: nextGap + 4)
            case .some(.none):
                break
            case .none:
                waits = true
            }
        }
        switch turn.status {
        case .cancelled:
            add("x-\(turnID)", .stopped)
        case .failed:
            add("x-\(turnID)", .failed(prompt: turn.prompt, errorText: turn.errorText))
        case .completed:
            // The row's 44 pt targets reach 6 pt into the gap above, less its 2 pt top padding.
            add("a-\(turnID)", .actions(turn, isLast: context.isLast), gap: nextGap - 4)
        case .running:
            break
        }
        return (rows, waits)
    }
}

/// Which transcript rows UIKit draws (`ChatNativeLayout`); the rest stay SwiftUI.
enum ChatNativeEligibility {
    /// A kind with a native layout (math blocks need the web renderer).
    static func isCandidate(_ kind: ChatRow.Kind) -> Bool {
        switch kind {
        case .sessionStart, .prompt, .thought, .tool, .toolGroup, .edit, .editedFiles, .actions: true
        case .block(_, let block): if case .math = block.kind { false } else { true }
        default: false
        }
    }

    /// Drawn natively: a native kind in its resting state at a standard text size. At
    /// accessibility sizes every row is SwiftUI (its views stack and wrap there); an open tool
    /// row, group or thought shows its SwiftUI view. `isOpen` reads a disclosure by key.
    /// `isSettling`: a disclosure the person just tapped, opening or closing (`ChatDisclosures.settle`):
    /// its row is SwiftUI until the animation completes.
    static func drawsNatively(_ row: ChatRow, accessibilitySize: Bool, wrapCode: Bool = false, isOpen: (String) -> Bool?,
                              isSettling: (String) -> Bool = { _ in false }) -> Bool {
        guard !accessibilitySize, isCandidate(row.kind) else { return false }
        switch row.kind {
        case .tool(let call) where isSettling("tool-\(call.id)"): return false
        case .toolGroup(let calls, _) where isSettling("group-\(calls.first?.id ?? "")"): return false
        case .thought where isSettling("thought-\(row.id)"): return false
        default: break
        }
        switch row.kind {
        // The native snippet draws its lines unwrapped; with "Wrap code and diff lines" on, the
        // SwiftUI snippet wraps them.
        case .edit: return !wrapCode
        case .tool(let call): return isOpen("tool-\(call.id)") != true
        case .toolGroup(let calls, _): return isOpen("group-\(calls.first?.id ?? "")") != true
        case .thought: return isOpen("thought-\(row.id)") == nil
        default: return true
        }
    }
}

/// Each row's content revision, from one counter that only goes up: a row that leaves the
/// transcript and comes back (a turn's working label) gets a revision it never had, so a
/// height measured for its old content is never taken for the new.
struct ChatRowRevisions {
    private(set) var values: [String: Int] = [:]
    private var counter = 0

    subscript(id: String) -> Int? { values[id] }

    /// A new revision for `id` (its content changed or it is new).
    @discardableResult
    mutating func bump(_ id: String) -> Int {
        counter += 1
        values[id] = counter
        return counter
    }

    /// The revision the next `bump` will hand out.
    var next: Int { counter + 1 }

    mutating func retain(_ ids: Set<String>) {
        values = values.filter { ids.contains($0.key) }
    }

    /// A new transcript (the counter keeps going).
    mutating func removeAll() {
        values = [:]
    }
}
