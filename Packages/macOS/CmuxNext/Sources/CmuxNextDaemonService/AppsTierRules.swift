public import Foundation
import CmuxNextCloud

/// The Apps tier's rules (RFD 0003 E-A and E-C, behind `experiments.appsTier`), asked of Rust
/// (`cmux_apps::ui`, with its tests) over the app FFI's JSON channel (ops `apps_tier_*`). The app
/// reads the facts (the page, the previews it opened, the account's app list, a publish's
/// output), asks here, and only draws what comes back.
public nonisolated struct AppsTierRules: Sendable {
    /// A Cloud preview this app opened: its page origin, and the machine port behind it.
    public struct KnownPreview: Codable, Equatable, Sendable {
        public var machine: String
        public var machineName: String
        public var port: Int
        public var origin: String

        public init(machine: String, machineName: String, port: Int, origin: String) {
            self.machine = machine
            self.machineName = machineName
            self.port = port
            self.origin = origin
        }
    }

    /// What Publish would publish: the machine port behind the page, and a name to start from.
    public struct Target: Codable, Equatable, Sendable {
        public var machine: String
        public var machineName: String
        public var port: Int
        public var origin: String
        public var suggestedName: String
    }

    /// Who may open the published app.
    public enum Audience: String, Codable, CaseIterable, Sendable {
        case `private`
        case team
    }

    /// What the person typed or picked in the popover.
    public struct Draft: Codable, Equatable, Sendable {
        public var name: String?
        public var audience: Audience

        public init(name: String? = nil, audience: Audience = .private) {
            self.name = name
            self.audience = audience
        }
    }

    /// The popover, as the rules lay it out.
    public struct Popover: Codable, Equatable, Sendable {
        public var name: String
        /// Nil when the name makes no slug (``problem`` is `nameEmpty`).
        public var slug: String?
        public var hostLabel: String?
        public var audience: Audience
        public var startFrom: String
        public var machine: String
        public var machineName: String
        public var port: Int
        public var argv: [String]
        public var command: String
        public var canPublish: Bool
        public var problem: String?
    }

    /// How a publish ended.
    public struct Outcome: Codable, Equatable, Sendable {
        public var kind: String
        public var slug: String?
        public var version: Int?
        public var url: String?
        public var warnings: [String]?
        public var code: String?
        public var message: String?

        public var published: Bool { kind == "published" }
    }

    /// One row of the sidebar's Apps section.
    public struct Row: Codable, Equatable, Sendable, Identifiable {
        public var slug: String
        public var title: String
        public var detail: String
        public var dot: String
        public var pinned: Bool
        public var url: String?

        public var id: String { slug }
        public var live: Bool { dot == "live" }
    }

    /// The sidebar's Apps section: rows, the `+ Publish preview…` row, or a note when the list
    /// was refused.
    public struct Section: Codable, Equatable, Sendable {
        public var rows: [Row]
        public var publishRow: Bool
        public var error: String?

        public static let empty = Section(rows: [], publishRow: true, error: nil)
    }

    private let core = CloudStartCore()

    public init() {}

    /// The preview behind this page, or nil when Publish has nothing to publish here.
    public func target(url: String, title: String?, previews: [KnownPreview]) -> Target? {
        ask("apps_tier_target", Page(url: url, title: title, previews: previews))
    }

    /// The popover for a target and what the person has typed so far.
    public func popover(_ target: Target, _ draft: Draft) -> Popover? {
        ask("apps_tier_popover", PopoverRequest(target: target, draft: draft))
    }

    /// What a `cmux app publish --json` run on the machine said.
    public func outcome(stdout: String, stderr: String, exit: Int) -> Outcome? {
        ask("apps_tier_outcome", OutcomeRequest(stdout: stdout, stderr: stderr, exit: exit))
    }

    /// The Apps section for the account relay's list reply (`{ok, value: {items}}` or a refusal).
    public func section(_ listReply: [String: Any]) -> Section? {
        guard JSONSerialization.isValidJSONObject(listReply),
              let data = try? JSONSerialization.data(withJSONObject: listReply) else { return nil }
        return decode(core.callData("apps_tier_section", data, startingCapacity: 16_384))
    }

    private struct Page: Encodable {
        var url: String
        var title: String?
        var previews: [KnownPreview]
    }

    private struct PopoverRequest: Encodable {
        var target: Target
        var draft: Draft
    }

    private struct OutcomeRequest: Encodable {
        var stdout: String
        var stderr: String
        var exit: Int
    }

    private func ask<Request: Encodable, Reply: Decodable>(_ operation: String, _ request: Request) -> Reply? {
        // The Rust types are `rename_all = "camelCase"`: Swift's own property names, no key strategy.
        guard let data = try? JSONEncoder().encode(request) else { return nil }
        return decode(core.callData(operation, data, startingCapacity: 16_384))
    }

    private func decode<Reply: Decodable>(_ reply: Data?) -> Reply? {
        guard let reply else { return nil }
        return try? JSONDecoder().decode(Reply.self, from: reply)
    }
}
