import AppKit
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextPages
import CmuxNextSettings
import Foundation

/// Settings > Skills (Leo 2026-11-08): forwards the page's `cmux.settings.skills.list` and `.run` to this
/// Mac's daemon (`skills-*`, capability `skills-v1`), which finds, toggles and creates every skill. The page
/// draws and filters the rows (webviews/src/pages/settings/skills.ts); Open and Show in Finder ask
/// `skills-locate` for a listed skill's file, so the page never names a path the daemon did not list.
@MainActor
enum SettingsSkills {
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

    private static func send<N: Name>(_ services: AppServices?, _: N.Type, _ fields: [String: CmuxNextDaemon.JSONValue]) async throws -> CmuxNextDaemon.JSONValue {
        guard let connection = services?.machines.local.connection else { throw DaemonError.notConnected }
        return try await connection.request(Command<N>(fields: fields))
    }

    /// `{available, home, projects, skills}`; `available` false when the daemon is not connected or older.
    static func list(_ services: AppServices?) async throws -> CmuxNextSettings.JSONValue {
        do {
            guard case .object(var answer) = try await send(services, List.self, [:]) else { return ["available": .bool(false)] }
            answer["available"] = .bool(true)
            return try page(.object(answer))
        } catch DaemonError.notConnected, DaemonError.missingCapabilities {
            return ["available": .bool(false)]
        }
    }

    /// One gesture (`set_enabled`, `create`, `open`, `reveal`): `{skill}`, or `{error: code}` on a refusal.
    static func run(_ services: AppServices?, _ params: CmuxNextSettings.JSONValue) async throws -> CmuxNextSettings.JSONValue {
        guard case .object(var fields) = try JSONDecoder().decode(CmuxNextDaemon.JSONValue.self, from: JSONEncoder().encode(params)),
              case .string(let action)? = fields.removeValue(forKey: "action") else { throw PageError.invalidParams("action") }
        if let id = fields.removeValue(forKey: "id") { fields["skill_id"] = id }
        do {
            switch action {
            case "set_enabled": return try await page(send(services, SetEnabled.self, fields))
            case "create": return try await page(send(services, Create.self, fields))
            case "open", "reveal":
                guard case .object(let located) = try await send(services, Locate.self, fields),
                      case .string(let file)? = located["file"], let services else { return .object([:]) }
                let url = URL(fileURLWithPath: file)
                if action == "reveal" || !services.linkOpener.openFile(url, from: services.windows.active?.focusedPane, asText: true) {
                    NSWorkspace.shared.revealInBackground([url])
                }
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
