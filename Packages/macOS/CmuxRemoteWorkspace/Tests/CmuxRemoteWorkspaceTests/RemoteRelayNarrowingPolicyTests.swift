import Foundation
import Testing
@testable import CmuxRemoteWorkspace

@Suite("Remote relay narrowing: resume bindings and notification replies")
struct RemoteRelayNarrowingPolicyTests {
    private let owner = UUID()
    private let surface = UUID()

    @Test("resume registration is not a relay method, with or without a command")
    func resumeRegistrationIsDenied() throws {
        #expect(RemoteRelayRoutingSchema().parameters(for: "surface.resume.set") == nil)
        let selectors: [String: Any] = ["workspace_id": owner.uuidString, "surface_id": surface.uuidString]
        let attempts: [[String: Any]] = [
            selectors,
            selectors.merging(["command": "codex resume session"]) { $1 },
            selectors.merging(["name": "codex", "kind": "codex", "cwd": "/tmp", "checkpoint_id": "c"]) { $1 },
            selectors.merging(["environment": ["PATH": "/usr/bin"], "launch_command": ["argv": ["codex"]]]) { $1 },
        ]
        for params in attempts {
            #expect(decision("surface.resume.set", params)
                == .denied(code: "remote_relay_method_denied", message: "Relay method is not permitted"))
            #expect(commandVerdict("surface.resume.set", params) != .allow)
        }
        #expect(!RemoteRelayCommandPolicy().permittedMethods(from: ["surface.resume.set"]).contains("surface.resume.set"))
    }

    @Test("resume reads and clears are not relay methods", arguments: ["surface.resume.get", "surface.resume.clear"])
    func resumeReadAndClearAreDenied(method: String) throws {
        #expect(RemoteRelayRoutingSchema().parameters(for: method) == nil)
        let selectors: [String: Any] = ["workspace_id": owner.uuidString, "surface_id": surface.uuidString]
        for params in [selectors, selectors.merging(["claim_checkpoint_id": "c", "claim_source": "agent-hook"]) { $1 }] {
            #expect(decision(method, params)
                == .denied(code: "remote_relay_method_denied", message: "Relay method is not permitted"))
            #expect(commandVerdict(method, params) != .allow)
        }
        #expect(!RemoteRelayCommandPolicy().permittedMethods(from: [method]).contains(method))
    }

    @Test("relay notifications cannot request a reply field", arguments: ["text", "none", ""])
    func notificationReplyShapeIsDenied(replyShape: String) throws {
        let params: [String: Any] = [
            "workspace_id": owner.uuidString,
            "surface_id": surface.uuidString,
            "title": "Build finished",
            "body": "ok",
            "reply_shape": replyShape,
        ]
        #expect(decision("notification.create_for_target", params) != .allowed)
        #expect(commandVerdict("notification.create_for_target", params) != .allow)
    }

    @Test("relay notifications without a reply field still deliver")
    func notificationWithoutReplyShapeIsAllowed() throws {
        let params: [String: Any] = [
            "workspace_id": owner.uuidString,
            "surface_id": surface.uuidString,
            "title": "Build finished",
            "subtitle": "remote",
            "body": "ok",
        ]
        #expect(decision("notification.create_for_target", params) == .allowed)
        #expect(commandVerdict("notification.create_for_target", params) == .allow)
    }

    @Test("relay notifications may toggle the command effect")
    func notificationCommandEffectIsAllowed() throws {
        let params: [String: Any] = [
            "workspace_id": owner.uuidString,
            "surface_id": surface.uuidString,
            "title": "Build finished",
            "effects": ["command": true, "desktop": false],
        ]
        #expect(decision("notification.create_for_target", params) == .allowed)
        #expect(commandVerdict("notification.create_for_target", params) == .allow)
    }

    @Test("a command key outside a boolean notification effects object is still denied")
    func commandKeyOutsideTheEffectsPatchIsDenied() throws {
        let selectors: [String: Any] = [
            "workspace_id": owner.uuidString,
            "surface_id": surface.uuidString,
            "title": "Build finished",
        ]
        let attempts: [(method: String, params: [String: Any])] = [
            ("notification.create_for_target", selectors.merging(["command": "id"]) { $1 }),
            ("notification.create_for_target", selectors.merging(["command": true]) { $1 }),
            ("notification.create_for_target", selectors.merging(["effects": ["command": "id"]]) { $1 }),
            ("notification.create_for_target", selectors.merging(["effects": ["command": 1]]) { $1 }),
            ("notification.create_for_target", selectors.merging(["effects": ["command": ["argv": ["id"]]]]) { $1 }),
            ("notification.create_for_target", selectors.merging(["effects": ["command": true, "script": true]]) { $1 }),
            ("notification.create_for_target", selectors.merging(["body": ["command": true]]) { $1 }),
            ("surface.send_text", selectors.merging(["text": "x", "effects": ["command": true]]) { $1 }),
        ]
        for attempt in attempts {
            #expect(decision(attempt.method, attempt.params) != .allowed, "\(attempt.params)")
            #expect(commandVerdict(attempt.method, attempt.params) != .allow, "\(attempt.params)")
        }
    }

    private func decision(_ method: String, _ parameters: [String: Any]) -> RemoteRelayAuthorizationPolicy.Decision {
        RemoteRelayAuthorizationPolicy().validate(method: method, parameters: parameters,
            ownerWorkspaceID: owner, surfaceIDs: [surface])
    }

    private func commandVerdict(_ method: String, _ parameters: [String: Any]) -> RemoteRelayCommandPolicy.Verdict {
        guard let request = try? JSONSerialization.data(withJSONObject: ["method": method, "params": parameters]) else {
            return .deny(reason: "unencodable test request")
        }
        return RemoteRelayCommandPolicy().evaluate(
            commandLine: request, workspaceAliases: [owner: owner], surfaceAliases: [surface: surface]
        )
    }
}
