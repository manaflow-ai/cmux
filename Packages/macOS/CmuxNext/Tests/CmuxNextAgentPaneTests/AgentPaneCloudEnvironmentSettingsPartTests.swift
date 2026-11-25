import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Settings > Cloud > Cloud Environments (#47676): `cmux.settings.cloud_environment` runs the composer's editor
/// request, reads at once, writes only on the person's own input in Settings, and answers the runner's failure
/// with its code (the page maps `cloud_disabled` and the platform's refusals).
@MainActor
struct AgentPaneCloudEnvironmentSettingsPartTests {
    private let settings = PageDescriptor.settings.id

    private func call(_ part: AgentPaneCloudEnvironmentSettingsPart, _ method: String, _ params: JSONValue = .object([:]),
                      page: String? = nil, gesture: Bool = false) async throws -> JSONValue {
        try await part.call(AgentPaneCloudEnvironmentSettingsPart.op,
                            params: .object(["method": .string(method), "params": params]),
                            context: PageCallContext(page: page ?? settings, userGesture: gesture))
    }

    @Test func aListReadsWithoutAGestureAndAnswersThePlatformsArray() async throws {
        var sent: [String] = []
        let part = AgentPaneCloudEnvironmentSettingsPart { request in
            sent.append(request.action)
            return AgentPaneReply.success([["id": "env_default", "is_default": true]])
        }
        let value = try await call(part, "cloud.environment.list")
        #expect(sent == ["list"])
        #expect(value == .array([.object(["id": .string("env_default"), "is_default": .bool(true)])]))
    }

    @Test func anUpdateOrCreateRunsOnlyOnThePersonsInputInSettings() async throws {
        var sent: [String] = []
        let part = AgentPaneCloudEnvironmentSettingsPart { request in
            sent.append(request.action)
            return AgentPaneReply.success(["id": "env_default"])
        }
        let patch: JSONValue = .object(["id": .string("env_default"), "patch": .object(["setup_script": .string("bun install")])])
        for (method, params) in [("cloud.environment.update", patch),
                                 ("cloud.environment.create", .object(["environment": .object(["name": .string("docs")])]))] {
            await #expect(throws: PageError.self) { try await call(part, method, params) }
            await #expect(throws: PageError.self) { try await call(part, method, params, page: "cmux.cloud", gesture: true) }
            #expect(sent.isEmpty)
        }
        _ = try await call(part, "cloud.environment.update", patch, gesture: true)
        _ = try await call(part, "cloud.environment.create",
                           .object(["environment": .object(["name": .string("docs")])]), gesture: true)
        #expect(sent == ["update", "create"])
    }

    @Test func theRunnersFailureKeepsItsCodeAndAnUnknownMethodSendsNothing() async throws {
        var sent = 0
        let part = AgentPaneCloudEnvironmentSettingsPart { _ in
            sent += 1
            return AgentPaneReply.failure(code: "cloud_disabled", message: "cloud_disabled")
        }
        do {
            _ = try await call(part, "cloud.environment.list")
            Issue.record("expected cloud_disabled")
        } catch let error as PageError {
            #expect(error.code == "cloud_disabled")
        }
        await #expect(throws: PageError.self) { try await call(part, "cloud.environment.delete") }
        #expect(sent == 1)
    }
}
