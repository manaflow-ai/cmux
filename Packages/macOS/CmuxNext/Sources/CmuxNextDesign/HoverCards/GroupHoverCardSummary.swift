import CCmuxLayoutReducerFFI
public import Foundation
public import CmuxNextDesignTokens

/// What a group's hover card says: its title and one block of lines per shown section, in the
/// order `GroupHoverCardOptions` picks. The rule (which sections show, the counts, the latest
/// member, the branch and port lists) is cmux-layout-reducer's (`group_hover_summary`, through
/// `cmux_layout_reducer_json`, once per card show); this type puts its typed lines into the
/// localized words (`GroupHoverCardStrings`). The sidebar's group headers and the tab strip's
/// group chips build it from their members, and `GroupHoverCardView` draws it.
public nonisolated struct GroupHoverCardSummary: Sendable, Hashable {
    /// The kind of group, for the member count's noun.
    public enum Kind: Sendable, Hashable {
        case workspaceGroup, tabGroup
    }

    /// The status line's color, mapped to a `HoverCardTone` where the card draws it (that type is
    /// main-actor isolated; this summary is built anywhere).
    public enum Tone: String, Sendable, Hashable, Decodable {
        case secondary, working, attention, danger
    }

    /// One shown section and its lines (never empty).
    public struct Block: Sendable, Hashable {
        public var section: GroupHoverCardOptions.Section
        public var lines: [String]
        /// The status block's tone: working, waiting or failed when one member is.
        public var tone: Tone
    }

    public var title: String
    public var blocks: [Block]

    /// Every line the card shows, the title first (tests, accessibility, `debug.hover_cards`).
    public var lines: [String] { [title] + blocks.flatMap(\.lines) }

    /// The summary of `members` as `options` asks for it, at `now`.
    /// - Parameters:
    ///   - title: The group's name (the caller supplies a default for an unnamed group).
    ///   - kind: Workspace group or tab group: the count reads "Workspaces" or "Tabs".
    ///   - members: The members in group order.
    ///   - options: Which sections show and in what order.
    ///   - now: The time ages are measured from.
    public static func make(title: String, kind: Kind, members: [GroupHoverCardMember],
                            options: GroupHoverCardOptions, now: Date) -> Self {
        let request = Wire.Request(
            members: members.map(Wire.Member.init), sections: options.sections.map(\.rawValue),
            max_members: options.maxMembers, now: now.timeIntervalSinceReferenceDate)
        // The rule cannot refuse a request this type builds; an empty card is the safe answer if it did.
        let blocks = (Wire.run(request)?.blocks ?? []).compactMap { block in block.words(kind) }
        return Self(title: title, blocks: blocks)
    }

    private static let ageFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 1
        formatter.allowedUnits = [.weekOfMonth, .day, .hour, .minute]
        return formatter
    }()

    /// "12m", "5h"; "Just now" when the rule says so (under a minute).
    static func age(seconds: Double, justNow: Bool) -> String {
        justNow ? GroupHoverCardStrings.justNow : ageFormatter.string(from: seconds) ?? GroupHoverCardStrings.justNow
    }

    /// The JSON of `group_hover_summary` (cmux-tui/crates/cmux-layout-reducer/src/group_hover_summary.rs).
    fileprivate nonisolated struct Wire {
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
            var tone: Tone
            var lines: [Line]

            func words(_ kind: Kind) -> GroupHoverCardSummary.Block? {
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
}

fileprivate nonisolated extension GroupHoverCardSummary.Wire.Line {
    /// The line in words.
    func words(_ kind: GroupHoverCardSummary.Kind) -> String {
        let listed = { (more: Int?) in (listed ?? "") + ((more ?? 0) > 0 ? " " + GroupHoverCardStrings.more(more ?? 0) : "") }
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
        case "branches": return GroupHoverCardStrings.branches(listed(more))
        default: return GroupHoverCardStrings.ports(listed(more))
        }
    }
}
