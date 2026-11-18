import CCmuxLayoutReducerFFI
import Foundation
import CmuxNextDesignTokens

/// The JSON of `group_hover_summary` (cmux-tui/crates/cmux-layout-reducer/src/group_hover_summary.rs) and
/// the call through `cmux_layout_reducer_json`. No rule lives here; `GroupHoverCardSummary` puts the
/// typed lines into words.
nonisolated struct GroupHoverCardSummaryWire {
    struct Member: Encodable {
        var title: String
        var activity: String
        var unread: Int
        var last_activity: Double?
        var branch: String?
        var ports: String?

        init(_ member: GroupHoverCardMember) {
            title = member.title
            activity = switch member.activity {
            case .idle: "idle"
            case .working: "working"
            case .waiting: "waiting"
            case .failed: "failed"
            }
            unread = member.unread
            // Foundation's reference date, as `now`: the rule's age is then `now.timeIntervalSince(date)`.
            last_activity = member.lastActivity?.timeIntervalSinceReferenceDate
            branch = member.branch
            ports = member.ports
        }
    }

    struct Request: Encodable {
        var members: [Member]
        var sections: [String]
        var max_members: Int
        var now: Double
    }

    struct Part: Decodable {
        var kind: String
        var count: Int
    }

    struct Line: Decodable {
        var line: String
        var parts: [Part]?
        var count: Int?
        var title: String?
        var age_seconds: Double?
        var just_now: Bool?
        var listed: String?
        var more: Int?
    }

    struct Block: Decodable {
        var section: String
        var tone: GroupHoverCardSummary.Tone
        var lines: [Line]

        func words(_ kind: GroupHoverCardSummary.Kind) -> GroupHoverCardSummary.Block? {
            guard let section = GroupHoverCardOptions.Section(rawValue: section) else { return nil }
            return GroupHoverCardSummary.Block(section: section, lines: lines.map { $0.words(kind) }, tone: tone)
        }
    }

    struct Response: Decodable {
        var blocks: [Block]
    }

    static func run(_ request: Request) -> Response? {
        guard let data = try? JSONEncoder().encode(request) else { return nil }
        var capacity = 4096
        for _ in 0..<2 {
            var output = [UInt8](repeating: 0, count: capacity); var outputLength = 0
            let code: Int32 = data.withUnsafeBytes { requestBytes in "group_hover_summary".withCString { operation in output.withUnsafeMutableBytes { outputBytes in cmux_layout_reducer_json(requestBytes.bindMemory(to: UInt8.self).baseAddress, data.count, operation, outputBytes.bindMemory(to: UInt8.self).baseAddress, outputBytes.count, &outputLength) } } }
            if code == CMUX_LAYOUT_REDUCER_ERR_BUFFER, outputLength > capacity {
                capacity = outputLength
                continue
            }
            guard code == CMUX_LAYOUT_REDUCER_OK, outputLength <= capacity else { return nil }
            return try? JSONDecoder().decode(Response.self, from: Data(output.prefix(outputLength)))
        }
        return nil
    }
}

nonisolated extension GroupHoverCardSummaryWire.Line {
    /// The line in words.
    func words(_ kind: GroupHoverCardSummary.Kind) -> String {
        // "a, b, c, d +2 more": the rule's list, then how many it left out.
        let list = (listed ?? "") + ((more ?? 0) > 0 ? " " + GroupHoverCardStrings.more(more ?? 0) : "")
        switch line {
        case "status":
            let parts = (parts ?? []).map { part in
                switch part.kind {
                case "working": GroupHoverCardStrings.working(part.count)
                case "waiting": GroupHoverCardStrings.waiting(part.count)
                case "failed": GroupHoverCardStrings.failed(part.count)
                default: GroupHoverCardStrings.unread(part.count)
                }
            }
            return parts.isEmpty ? GroupHoverCardStrings.allIdle : parts.joined(separator: " \u{00B7} ")
        case "count": return GroupHoverCardStrings.count(kind, count ?? 0)
        case "member": return "\u{2022} " + (title ?? "")
        case "more": return GroupHoverCardStrings.more(count ?? 0)
        case "latest":
            return GroupHoverCardStrings.latest(title ?? "", age: GroupHoverCardSummary.age(seconds: age_seconds ?? 0, justNow: just_now ?? true))
        case "branches": return GroupHoverCardStrings.branches(list)
        default: return GroupHoverCardStrings.ports(list)
        }
    }
}
