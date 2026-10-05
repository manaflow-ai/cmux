import Foundation
import Testing
@_spi(CmuxHostTransport) @testable import CmuxExtensionKit

@Suite
struct RuntimeObservationContractTests {
    @Test
    func sameSurfaceSessionsRoundTripWithoutLosingFeedbackOrMode() throws {
        let original = CmuxSidebarSurface(id: UUID(), title: "Project", runtimeObservations: [
            CmuxSidebarRuntimeObservation(lifecycle: .running, observedAt: Date(timeIntervalSince1970: 120), provenance: .nativeLifecycle, sessionID: "first", toolID: "codex", processGeneration: 100_000_001, activity: .working, mode: .execution, transitionedAt: Date(timeIntervalSince1970: 110), modeObservedAt: Date(timeIntervalSince1970: 105), sampledAt: Date(timeIntervalSince1970: 200)),
            CmuxSidebarRuntimeObservation(lifecycle: .needsInput, observedAt: Date(timeIntervalSince1970: 130), provenance: .nativeLifecycle, sessionID: "second", toolID: "codex", processGeneration: 101_000_002, activity: .needsInput, reason: .planReview, mode: .plan)
        ])
        let restored = try JSONDecoder().decode(CmuxSidebarSurface.self, from: JSONEncoder().encode(original))
        #expect(restored == original)
        #expect(restored.runtimeObservations?.map(\.activity) == [.working, .needsInput])
        #expect(restored.runtimeObservations?.map(\.sessionID) == ["first", "second"])
        #expect(restored.runtimeObservations?.last?.reason == .planReview)
        #expect(restored.runtimeObservations?.first?.sampledAt != restored.runtimeObservations?.first?.observedAt)
    }

    @Test
    func exactObservationsRequireRuntimeGrantAndLegacySurfaceDecodesWithoutThem() throws {
        let original = CmuxSidebarSurface(id: UUID(), title: "Project", runtime: .init(lifecycle: .running), runtimeObservations: [.init(activity: .working)])
        #expect(original.filtered(for: [.surfaceMetadata]).runtimeObservations == nil)
        #expect(original.filtered(for: [.surfaceMetadata]).runtime == nil)
        #expect(original.filtered(for: [.agentRuntime]).runtimeObservations == original.runtimeObservations)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object.removeValue(forKey: "runtimeObservations")
        let legacy = try JSONDecoder().decode(CmuxSidebarSurface.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(legacy.runtimeObservations == nil)
        #expect(legacy.runtime?.lifecycle == .running)
    }

    @Test
    func legacyObservationDoesNotInventSemanticActivityOrMode() throws {
        let old = Data(#"{"lifecycle":"running","provenance":"nativeLifecycle","sessionID":"old"}"#.utf8)
        let observation = try JSONDecoder().decode(CmuxSidebarRuntimeObservation.self, from: old)
        #expect(observation.lifecycle == .running)
        #expect(observation.activity == .unknown)
        #expect(observation.mode == .unknown)
        #expect(observation.reason == nil)
        #expect(observation.transitionedAt == nil)
        #expect(observation.sampledAt == nil)
        let plan = CmuxSidebarRuntimeObservation(mode: .plan)
        #expect(plan.activity == .unknown)
        #expect(plan.lifecycle == .unknown)
    }

    @Test
    func futureSemanticValuesStayUnknown() throws {
        #expect(try JSONDecoder().decode(CmuxSidebarAgentActivity.self, from: Data(#""future""#.utf8)) == .unknown)
        #expect(try JSONDecoder().decode(CmuxSidebarAgentMode.self, from: Data(#""future""#.utf8)) == .unknown)
        #expect(try JSONDecoder().decode(CmuxSidebarRuntimeReason.self, from: Data(#""future""#.utf8)) == .unknown)
    }

    @Test
    @MainActor
    func explicitBindingUsesItsOwnPermissionAndPreservesBirthGuard() async throws {
        let workspace = UUID(), surface = UUID()
        var actions: [CmuxSidebarAction] = []
        let host = CmuxSidebarHost(performAction: { action, reply in actions.append(action); reply(.accepted) })
        try await host.bindAgentSession(workspaceID: workspace, surfaceID: surface, toolID: "codex", sessionID: "exact-session", expectedProcessGeneration: 123_000_007)
        let action = try #require(actions.first)
        #expect(action.requiredScopes == [.bindAgentSession])
        #expect(try CmuxSidebarXPCCodec.decodeAction(CmuxSidebarXPCCodec.encodeAction(action)) == action)
        let manifest = CmuxExtensionManifest(id: "dev.test.binding", displayName: "Binding", actionScopes: [.bindAgentSession], minimumAPIVersion: .sidebarV2_1)
        #expect(throws: CmuxExtensionValidationError.scopeRequiresAPIVersion(scope: "bindAgentSession", required: .sidebarV2_2, declared: .sidebarV2_1)) { try validateSidebarManifest(manifest) }
    }
}
