// SPDX-License-Identifier: GPL-3.0-or-later
@testable import CmuxCuaHelperCore
import Foundation
import Testing

@Suite struct CuaTargetGuardTests {
    @Test(arguments: [
        #"{"pid":100}"#, #"{"window_id":9000}"#,
        #"{"pid":102,"window_id":9000}"#,
        #"{"app_name":"Terminal"}"#, #"{"bundle_id":"com.apple.Terminal"}"#,
        #"{"pid":100,"_cua_allowed_target_bundle_ids":["com.apple.Terminal"]}"#,
    ])
    func everyTargetIsChecked(arguments: String) async throws {
        let guarder = CuaTargetGuard(policy: CuaTargetPolicy(), resolver: Resolver())
        await #expect(throws: ToolError.self) {
            try await guarder.check(name: "click", arguments: Data(arguments.utf8))
        }
    }

    @Test func refusedTargetHasAnActionableError() async throws {
        do {
            _ = try await CuaTargetGuard(policy: CuaTargetPolicy(), resolver: Resolver())
                .check(name: "launch_app", arguments: Data(#"{"name":"Terminal"}"#.utf8))
            Issue.record("Terminal should be refused")
        } catch let error as ToolError {
            #expect(error.description == "Computer use is not allowed to use Terminal for safety reasons.")
        }
    }

    @Test(arguments: ["list_apps", "get_screen_size", "check_permissions"])
    func untargetedCallsPass(name: String) async throws {
        let arguments = Data("{}".utf8)
        let result = try await CuaTargetGuard(policy: CuaTargetPolicy(), resolver: Resolver())
            .check(name: name, arguments: arguments)
        #expect(result == arguments)
    }

    @Test func ordinaryTargetsPass() async throws {
        _ = try await CuaTargetGuard(policy: CuaTargetPolicy(), resolver: Resolver())
            .check(name: "click", arguments: Data(#"{"pid":102,"window_id":9001}"#.utf8))
    }

    @Test func nameLaunchIsPinnedToTheCheckedBundle() async throws {
        let result = try await CuaTargetGuard(policy: CuaTargetPolicy(), resolver: Resolver())
            .check(name: "launch_app", arguments: Data(#"{"name":"TextEdit"}"#.utf8))
        let arguments = try #require(JSONSerialization.jsonObject(with: result) as? [String: Any])
        #expect(arguments["bundle_id"] as? String == "com.apple.TextEdit")
    }

    @Test func ordinaryBundleLaunchPasses() async throws {
        _ = try await CuaTargetGuard(policy: CuaTargetPolicy(), resolver: Resolver())
            .check(name: "launch_app", arguments: Data(#"{"bundle_id":"com.apple.TextEdit"}"#.utf8))
    }

    @Test func cmuxDeepLinksAreRefused() async {
        await #expect(throws: ToolError.self) {
            try await CuaTargetGuard(policy: CuaTargetPolicy(), resolver: Resolver())
                .check(name: "launch_app", arguments: Data(#"{"name":"TextEdit","urls":["cmux://workspace/1"]}"#.utf8))
        }
    }

    @Test(arguments: [
        #"{"pid":999}"#, #"{"window_id":999}"#, #"{"pid":true}"#,
        #"{"pid":-1}"#, #"{"pid":4294967296}"#, #"{"pid":"100"}"#,
        #"{"window_id":4294967296}"#, #"{"window_id":true}"#,
        #"{"bundle_id":"example.missing"}"#, #"{"app_name":"Missing App"}"#,
    ])
    func unresolvedOrMalformedTargetsFailClosed(arguments: String) async {
        await #expect(throws: ToolError.self) {
            try await CuaTargetGuard(policy: CuaTargetPolicy(), resolver: Resolver())
                .check(name: "click", arguments: Data(arguments.utf8))
        }
    }

    @Test func trustedScopeUnlocksOnlyItsOwnTarget() async throws {
        _ = try await CuaTargetGuard(
            policy: CuaTargetPolicy(allowedBundleIDs: "com.apple.Terminal"), resolver: Resolver()
        ).check(name: "click", arguments: Data(#"{"pid":100}"#.utf8))
    }

    @Test(arguments: [
        #"{"scope":"desktop","x":10,"y":10}"#,
        #"{"scope":"desktop","pid":null,"window_id":null,"x":10,"y":10}"#,
    ])
    func desktopInputCannotBypassTargetChecks(arguments: String) async {
        await #expect(throws: ToolError.self) {
            try await CuaTargetGuard(policy: CuaTargetPolicy(), resolver: Resolver())
                .check(name: "click", arguments: Data(arguments.utf8))
        }
    }

    @Test func desktopObservationStillPasses() async throws {
        _ = try await CuaTargetGuard(policy: CuaTargetPolicy(), resolver: Resolver())
            .check(name: "get_desktop_state", arguments: Data(#"{"scope":"desktop"}"#.utf8))
    }

    @Test func alternateBundleIDIsCheckedByResolvedName() async {
        await #expect(throws: ToolError.self) {
            try await CuaTargetGuard(policy: CuaTargetPolicy(), resolver: Resolver())
                .check(name: "launch_app", arguments: Data(#"{"bundle_id":"example.Terminal"}"#.utf8))
        }
    }

    // Upstream v0.35+ tools whose inner calls the driver dispatches itself.
    @Test(arguments: ["run_script", "replay_trajectory"])
    func toolsThatHideTheirTargetsAreRefused(name: String) async {
        await #expect(throws: ToolError.self) {
            try await CuaTargetGuard(policy: CuaTargetPolicy(), resolver: Resolver())
                .check(name: name, arguments: Data(#"{"script":"cua.click({pid:100,x:1,y:1})"}"#.utf8))
        }
    }

    @Test(arguments: [
        // batch default, step {tool,args}, shorthand step, observe, nested refused selectors
        #"{"pid":100,"steps":[{"tool":"click","args":{"x":1,"y":1}}]}"#,
        #"{"steps":[{"tool":"click","args":{"pid":100,"x":1,"y":1}}]}"#,
        #"{"steps":[{"click":{"window_id":9000,"x":1,"y":1}}]}"#,
        #"{"pid":102,"steps":[{"tool":"click","args":{"x":1,"y":1}}],"observe":{"pid":100}}"#,
        #"{"steps":[{"tool":"click","args":{"app":"Calculator","role":"button","name":"7"}}]}"#,
        #"{"app":"TextEdit","steps":[{"tool":"press_key","args":{"key":"a"}}]}"#,
        #"{"pid":102,"steps":[{"tool":"click","args":{"window":"Terminal","x":1,"y":1}}]}"#,
        #"{"pid":102,"steps":[{"tool":"click","args":{"element_token":"s00000001:3"}}]}"#,
        #"{"steps":[{"tool":"click","args":{"scope":"desktop","x":1,"y":1}}]}"#,
        #"{"steps":[{"tool":"type_text","args":{"app_name":"Terminal","text":"ls"}}]}"#,
    ])
    func everyBatchTargetIsChecked(arguments: String) async {
        for name in ["run_steps", "run_actions"] {
            await #expect(throws: ToolError.self) {
                try await CuaTargetGuard(policy: CuaTargetPolicy(), resolver: Resolver())
                    .check(name: name, arguments: Data(arguments.utf8))
            }
        }
    }

    @Test func batchWithCheckedWindowsPasses() async throws {
        let arguments = Data(#"{"pid":102,"window_id":9001,"steps":[{"tool":"click","args":{"element_token":"s00000001:3","pid":102}},{"type_text":{"text":"hi"},"expect":[{"role":"button","name":"Save"}]}],"observe":{}}"#.utf8)
        let result = try await CuaTargetGuard(policy: CuaTargetPolicy(), resolver: Resolver())
            .check(name: "run_steps", arguments: arguments)
        #expect(result == arguments)
    }

    @Test func elementTokenNeedsItsPid() async throws {
        let guarder = CuaTargetGuard(policy: CuaTargetPolicy(), resolver: Resolver())
        await #expect(throws: ToolError.self) {
            try await guarder.check(name: "set_value", arguments: Data(#"{"element_token":"s00000001:3","value":"x"}"#.utf8))
        }
        _ = try await guarder.check(name: "set_value", arguments: Data(#"{"element_token":"s00000001:3","pid":102,"value":"x"}"#.utf8))
    }

    private struct Resolver: CuaTargetResolving {
        func app(forPID pid: Int32) async -> CuaTargetIdentity? {
            switch pid {
            case 100: CuaTargetIdentity(bundleID: "com.apple.Terminal", name: "Terminal")
            case 102: CuaTargetIdentity(bundleID: "com.apple.TextEdit", name: "TextEdit")
            default: nil
            }
        }
        func app(forWindowID id: UInt32) async -> CuaTargetIdentity? {
            await app(forPID: id == 9000 ? 100 : id == 9001 ? 102 : 999)
        }
        func app(named name: String) async -> CuaTargetIdentity? {
            await app(forPID: name == "Terminal" ? 100 : name == "TextEdit" ? 102 : 999)
        }
        func app(forBundleID id: String) async -> CuaTargetIdentity? {
            await app(forPID: id == "com.apple.Terminal" || id == "example.Terminal" ? 100
                : id == "com.apple.TextEdit" ? 102 : 999)
        }
    }
}
