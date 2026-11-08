public import AppKit
import CmuxNextCompat
public import CmuxNextDaemon
import CmuxNextDaemonService
public import CmuxNextPages
public import CmuxNextSettings
public import Foundation

/// Settings > Skills (Leo 2026-11-08): forwards the page's `cmux.settings.skills.list` and `.run` to this
/// Mac's daemon (`skills-*`, capability `skills-v1`), which finds, toggles and creates every skill. The page
/// draws and filters the rows (webviews/src/pages/settings/skills.ts); Open and Show in Finder ask
/// `skills-locate` for a listed skill's file, so the page never names a path the daemon did not list.
/// The App supplies this Mac's daemon connection and cmux's file opener, and routes the ops here.
@MainActor
public final class SettingsSkills: PageProvider {
    private nonisolated protocol Name { static var command: String { get } }
    private nonisolated enum List: Name { static let command = "skills-list" }
    private nonisolated enum SetEnabled: Name { static let command = "skills-set-enabled" }
    private nonisolated enum Create: Name { static let command = "skills-create" }
    private nonisolated enum Locate: Name { static let command = "skills-locate" }

    /// One `skills-*` command with the page's params as given (the skill's id as `skill_id`: the envelope's
    /// `id` is the request's number); answered as is.
    private nonisolated struct Command<N: Name>: DaemonRequest {
        typealias Response = CmuxNextDaemon.JSONValue
        static var command: String { N.command }
        static var requiredCapability: String? { "skills-v1" }
        let fields: [String: CmuxNextDaemon.JSONValue]
        /// A keyed container, as every request's fields: the envelope adds `id` and `cmd` to the same one.
        private struct Key: CodingKey {
            let stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue _: Int) { nil }
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: Key.self)
            for (name, value) in fields { try container.encode(value, forKey: Key(stringValue: name)) }
        }
    }

    private let connection: @MainActor () -> DaemonConnection?
    /// Opens a file in cmux's editor; false when it could not (Show in Finder then).
    private let open: @MainActor (URL) -> Bool

    public init(connection: @escaping @MainActor () -> DaemonConnection?, open: @escaping @MainActor (URL) -> Bool) {
        self.connection = connection
        self.open = open
    }

    /// `cmux.settings.skills.list` and `.run`; any other op is not this card's.
    public func call(_ op: String, params: CmuxNextSettings.JSONValue, context: PageCallContext) async throws -> CmuxNextSettings.JSONValue {
        switch op {
        case "cmux.settings.skills.list": return try await list()
        case "cmux.settings.skills.run":
            // Only the Settings page asks. Turning a skill on or off and making one change the person's
            // agent configs, so they run only on the person's own click or key in the page
            // (`context.userGesture`) or a call they approved, as the Agent integrations card's
            // installs do; a page script alone gets `cmux.app.user_only`. Open and Show in Finder
            // write nothing.
            let writes = ["set_enabled", "create"].contains(params["action"]?.stringValue ?? "")
            guard context.page == PageDescriptor.settings.id, !writes || context.userGesture || context.isConfirmedUser else {
                throw PageError(code: PageNativeOp.userOnlyCode, message: RefusalStrings.personOnlyFromPage)
            }
            return try await run(params)
        default: throw PageError.unknownOp(op)
        }
    }

    private func send<N: Name>(_: N.Type, _ fields: [String: CmuxNextDaemon.JSONValue]) async throws -> CmuxNextDaemon.JSONValue {
        guard let connection = connection() else { throw DaemonError.notConnected }
        return try await connection.request(Command<N>(fields: fields))
    }

    /// `{available, home, projects, skills}`; `available` false when the daemon is not connected or older.
    private func list() async throws -> CmuxNextSettings.JSONValue {
        do {
            guard case .object(var answer) = try await send(List.self, [:]) else { return ["available": .bool(false)] }
            answer["available"] = .bool(true)
            return try Self.page(.object(answer))
        } catch DaemonError.notConnected, DaemonError.missingCapabilities {
            return ["available": .bool(false)]
        }
    }

    /// One gesture (`set_enabled`, `create`, `open`, `reveal`): `{skill}`, or `{error: code}` on a refusal.
    private func run(_ params: CmuxNextSettings.JSONValue) async throws -> CmuxNextSettings.JSONValue {
        guard case .object(var fields) = try JSONDecoder().decode(CmuxNextDaemon.JSONValue.self, from: JSONEncoder().encode(params)),
              case .string(let action)? = fields.removeValue(forKey: "action") else { throw PageError.invalidParams("action") }
        if let id = fields.removeValue(forKey: "id") { fields["skill_id"] = id }
        do {
            switch action {
            case "set_enabled": return try await Self.page(send(SetEnabled.self, fields))
            case "create": return try await Self.page(send(Create.self, fields))
            case "open", "reveal":
                guard case .object(let located) = try await send(Locate.self, fields),
                      case .string(let file)? = located["file"] else { return .object([:]) }
                let url = URL(fileURLWithPath: file)
                if action == "reveal" || !open(url) { NSWorkspace.shared.revealInBackground([url]) }
                return .object([:])
            default: throw PageError.invalidParams("unknown skills action \(action)")
            }
        } catch DaemonError.command(_, _, let code?, _, _) {
            return ["error": .string(code)]
        }
    }

    private static func page(_ value: CmuxNextDaemon.JSONValue) throws -> CmuxNextSettings.JSONValue {
        try CmuxNextSettings.JSONValue.parse(JSONEncoder().encode(value))
    }
}
