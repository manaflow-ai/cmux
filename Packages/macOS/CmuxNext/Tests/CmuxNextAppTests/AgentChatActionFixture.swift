import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextControl
import CmuxNextDaemon
import Testing

/// Real workspace-daemon creation and folder resolution, with an isolated handshake host.
/// The inert page leaves ready to the test instead of racing JavaScript for the one-shot seed.
@MainActor
enum AgentChatActionFixture {
    // The daemon canonicalizes local folders (/tmp is /private/tmp on a Mac). Supply the
    // canonical spelling so equality still tests exactly the requested directory.
    static let localCwd = "/private/tmp"

    static let environment = [
        AgentPaneSource.devURLVariable: "http://127.0.0.1:9",
        "CMUX_NEXT_AGENT_PANE_MOCK": "1",
    ]

    static func withApp(_ body: (AppServices, DaemonConnection) async throws -> Void) async throws {
        try await PasswordManagerRouteTests.withApp(agentPaneEnvironment: environment) { services, connection in
            // Restore may have mounted an optimistic first tab. Let that settle before a
            // test records the identities which existed before its New Agent Chat action.
            try await PasswordManagerRouteTests.until {
                !PasswordManagerRouteTests.tabs(services).contains { ProvisionalTab.isProvisional($0.id) }
            }
            try await body(services, connection)
        }
    }

    static func finish(_ run: ControlActionRun) async throws -> [String: ActionResultValue] {
        try #require(run.outcome == .ran, "\(run.outcome)")
        for work in run.work { try #require(await work.value == nil) }
        var fields: [String: ActionResultValue] = [:]
        for result in run.results {
            fields.merge(try await result.value.get(), uniquingKeysWith: { _, new in new })
        }
        return fields
    }

    /// The command reply may precede the store projection. Never use its optimistic stand-in
    /// as the identity of the created chat: that alias disappears when creation settles.
    static func created(in services: AppServices, after before: Set<String>,
                        fields: [String: ActionResultValue]) async throws -> TabModel {
        func matching() -> TabModel? {
            PasswordManagerRouteTests.tabs(services).first { tab in
                guard !before.contains(tab.id), !ProvisionalTab.isProvisional(tab.id), tab.agentSession != nil else { return false }
                if case .string(let id)? = fields["tab"] { return tab.id == id }
                return true
            }
        }
        try await PasswordManagerRouteTests.until({ matching() != nil }, report: {
            "created \(fields); store tabs \(PasswordManagerRouteTests.tabs(services).map(\.id))"
        })
        return try #require(matching())
    }
}
