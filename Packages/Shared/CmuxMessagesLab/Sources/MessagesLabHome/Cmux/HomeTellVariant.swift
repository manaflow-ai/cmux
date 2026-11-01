#if DEBUG
import CmuxHomeCore
import Foundation

/// SCRATCH, DEBUG ONLY (scratch-chief-tell-variants, never feat-cmux-next): prototypes of how one of
/// the Chief's messages to an agent (a tell) shows in Home (Lawrence 2026-10-31, msg 19228: "where's
/// the chief->agent ui, i want to see variations of it"). `debug.home.drive` `agent_messages` with `variant` picks one.
/// Captions and words are draft English.
enum HomeTellVariant {
    /// The first line of a tell's text that picks variant N (`⟦tell-variant N⟧`); the renderer strips it.
    static func marker(_ number: Int) -> String { "⟦tell-variant \(number)⟧\n" }

    static let captions: [String] = [
        "T0 Landed today: a bubble with a bold \"Chief → a948\" line over the whole message.",
        "T1 Collapsed one line (default pick): \"▸ → a948: first words…\" in one short bubble; a click expands it to T0.",
        "T2 Muted system line: one italic line \"→ a948 · told: first words…\", no bubble emphasis.",
        "T3 Quote card with the agent's chip: the agent's chip (icon + name, opens its chat) over the message as a quote.",
        "T4 \"Sent to\" chip header: \"Sent to [a948 chip]\", then the message as plain text.",
        "T5 Hidden behind a count chip: only \"→ 1 message to a948\"; a click shows it.",
        "T6 Relayed: \"↳ Relayed your message to [a948 chip]:\" over the message as a quote (ties it to what you asked).",
        "T7 Log block: the arrow line and the message in a monospaced block.",
        "T8 Minimal arrow: a plain \"→ a948\" line (not bold) over the message.",
        "T9 Footnote: \"↗ told [a948 chip] · show message\", the message itself hidden.",
        "T10 Inline label: \"To a948:\" in bold, the message runs on after it.",
    ]

    /// The tell's Markdown for the variant its text's marker names; nil keeps the landed look (T0, or no marker).
    static func text(from: String, to: String, body marked: String, group: String) -> String? {
        guard let current = captions.indices.first(where: { marked.hasPrefix(marker($0)) }) else { return nil }
        let body = String(marked.dropFirst(marker(current).count))
        let chip = "[\(to)](cmux://chief/0123abcd/session/\(to))"
        let toggle = HomeAgentMessageRow.toggleLink(group: group)
        let firstLine = body.split(separator: "\n").first.map(String.init) ?? body
        let short = firstLine.count <= 56 ? firstLine : String(firstLine.prefix(56)).trimmingCharacters(in: .whitespaces) + "…"
        let quoted = body.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n")
        switch current {
        case 1: return "[▸ → \(to)](\(toggle)): \(short)"
        case 2: return "*→ \(to) · told: \(short)*"
        case 3: return "\(chip)\n\(quoted)"
        case 4: return "Sent to \(chip)\n\(body)"
        case 5: return "[→ 1 message to \(to)](\(toggle))"
        case 6: return "↳ *Relayed your message to* \(chip):\n\(quoted)"
        case 7: return "```\n→ \(to)\n\(body)\n```"
        case 8: return "→ \(to)\n\(body)"
        case 9: return "↗ told \(chip) · [show message](\(toggle))"
        case 10: return "**To \(to):** \(body)"
        default: return "**\(from) → \(to)**\n\(body)"
        }
    }
}

extension MessagesLabHomeView {
    /// SCRATCH: the first line that makes a tell's text draw as Chief → agent prototype `number` (0...10).
    public static func debugTellMarker(_ number: Int) -> String { HomeTellVariant.marker(number) }
}
#endif
