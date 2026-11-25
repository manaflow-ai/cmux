import Foundation

/// A finished turn's work folded under one line, "Worked for 1m 9s ›", with the turn's final reply
/// under it, as the Mac transcript folds a turn (`webviews/src/agent-session/acpmux/conversation/turns.ts`
/// `workedLabel`, `formatDuration`). Leo, 2026-11-17, on the phone's chat: "can we also just for the
/// gui on ios collapse the agent messages that come in by default? rn they're all showing ... rn
/// they're just all expanded and it's kinda undreadable :(". The thoughts, tool runs, edits, plans
/// and the notes the agent wrote between them fold; the last reply, a next-step card, the
/// edited-files card, the actions and an error card stay. A message the person steered in stays
/// where it went in. A running turn shows its work as it happens and folds when it ends.
struct WorkedFold: Equatable, Sendable {
    var turnID: String
    /// The line: "Worked for 1m 9s", "Failed after 40s", "You stopped after 40s", or "Worked" when
    /// the turn's time is unknown.
    var label: String
    /// The rows it holds, in the turn's order, drawn under the line when it is open.
    var rows: [ChatRow]

    /// The transcript's disclosure key for the fold (`ChatDisclosures`).
    var key: String { Self.key(turnID: turnID) }
    static func key(turnID: String) -> String { "worked-\(turnID)" }

    /// The fold's row id in the transcript.
    static func rowID(turnID: String) -> String { "wk-\(turnID)" }

    /// The line for a turn that ended `status` after `seconds` (the Mac's `turnTimeKey`).
    static func label(status: AgentTurn.Status, seconds: TimeInterval?) -> String {
        guard let seconds, seconds >= 0 else { return status == .failed ? "Failed" : (status == .cancelled ? "You stopped" : "Worked") }
        let time = duration(seconds)
        switch status {
        case .failed: return "Failed after \(time)"
        case .cancelled: return "You stopped after \(time)"
        default: return "Worked for \(time)"
        }
    }

    /// "1m 16s", "42s", "1h 3m": zero units dropped, under one second "0s" (the Mac's `formatDuration`).
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        guard total > 0 else { return "0s" }
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return [h > 0 ? "\(h)h" : nil, m > 0 ? "\(m)m" : nil, s > 0 ? "\(s)s" : nil].compactMap(\.self).joined(separator: " ")
    }

    /// Whether a row of a finished turn's work folds. The person's own words (a steered message)
    /// and the cards a finished turn leaves for the person stay out.
    static func folds(_ kind: ChatRow.Kind) -> Bool {
        switch kind {
        case .block, .thought, .tool, .toolGroup, .edit, .plan, .permission, .question, .subagents, .whoElse: true
        default: false
        }
    }

    /// Folds `rows[work]` of a turn that ended `status` (its work: everything after its prompt and
    /// before its closing cards), keeping the rows in `reply` (the final reply's blocks) and every
    /// row that does not fold. The fold's line takes the place of the first row it holds. Nil when
    /// nothing folds.
    @discardableResult
    static func fold(_ rows: inout [ChatRow], work: Range<Int>, keeping reply: Set<String>, turnID: String,
                     status: AgentTurn.Status, seconds: TimeInterval?) -> WorkedFold? {
        guard !work.isEmpty else { return nil }
        var held: [ChatRow] = []
        var kept: [ChatRow] = []
        var at: Int?
        for row in rows[work] {
            if !reply.contains(row.id), folds(row.kind) {
                if at == nil { at = kept.count }
                held.append(row)
            } else {
                kept.append(row)
            }
        }
        guard let at, let first = held.first else { return nil }
        let fold = WorkedFold(turnID: turnID, label: label(status: status, seconds: seconds), rows: held)
        kept.insert(ChatRow(id: rowID(turnID: turnID), turnID: turnID, kind: .worked(fold), gap: first.gap), at: at)
        // What follows the line sits a tool row's gap under it.
        if at + 1 < kept.count { kept[at + 1].gap = min(kept[at + 1].gap, 10) }
        rows.replaceSubrange(work, with: kept)
        return fold
    }
}

#if os(iOS)
import CmuxMobileDesign
import SwiftUI

/// `WorkedFold` in the transcript: the line, and open, the turn's work under it drawn by the rows'
/// own views. Closed at rest it is drawn natively (`ChatNativeWidgets.worked`).
struct WorkedForRow: View {
    let fold: WorkedFold
    let context: ChatRowContext
    @Environment(\.chatDisclosures) private var disclosures
    @Environment(\.transcriptFoldHold) private var holdFold
    @State private var localOpen = false

    private var open: Bool { disclosures?.isOpen(fold.key) ?? localOpen }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                toggleDisclosure(holdFold, key: fold.key, in: disclosures) {
                    if let disclosures { disclosures.set(fold.key, !open) } else { localOpen.toggle() }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(fold.label).font(.subheadline).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                    Spacer(minLength: 0)
                }
                // 44 pt hit target on a 32 pt row (the extra overlaps the row gaps).
                .frame(minHeight: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.cmuxPressLine)
            .padding(.vertical, -6)
            .zIndex(1)
            .accessibilityValue(open ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("agent-chat.worked-for")
            if open {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(fold.rows) { row in
                        // Erased: a row view holding row views has no concrete type of its own.
                        AnyView(ChatRowView(row: row, context: context))
                            .padding(.top, row.id == fold.rows.first?.id ? 10 : row.gap)
                    }
                }
                .transition(.disclosureReveal)
            }
        }
    }
}
#endif
