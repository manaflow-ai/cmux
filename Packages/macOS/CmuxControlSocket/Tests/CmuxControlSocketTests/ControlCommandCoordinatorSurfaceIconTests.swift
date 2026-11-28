import Foundation
import Testing
@testable import CmuxControlSocket

@Suite("Surface icon wire parsing and worker dispatch")
struct ControlCommandCoordinatorSurfaceIconTests {
    private let workspaceID = UUID(uuidString: "AABBCCDD-1111-2222-3333-444455556666")!
    private let surfaceID = UUID(uuidString: "AABBCCDD-1111-2222-3333-444455557777")!

    private func frame(svg: String = "<svg/>", duration: JSONValue = .int(100)) -> JSONValue {
        .object(["svg": .string(svg), "duration_ms": duration])
    }

    private func asset(frames: [JSONValue]? = nil) -> JSONValue {
        .object(["frames": .array(frames ?? [frame()]), "loop": .bool(true)])
    }

    private func params() -> [String: JSONValue] {
        [
            "workspace_id": .string(workspaceID.uuidString.lowercased()),
            "surface_id": .string(surfaceID.uuidString),
            "owner_id": .string("agent-status"),
            "expected_agent_pid": .int(12345),
            "expected_process_start": .string("generation-1"),
            "asset": asset(),
        ]
    }

    @Test func parsesRawAssetAndDefaultsWithoutRendering() throws {
        let inputs = try ControlSurfaceIconParser().parse(params(), clear: false)
        #expect(inputs.operation == .set)
        #expect(inputs.workspaceID == workspaceID)
        #expect(inputs.surfaceID == surfaceID)
        #expect(inputs.ownerID == "agent-status")
        #expect(inputs.expectedAgentPID == 12345)
        #expect(inputs.expectedProcessStart == "generation-1")
        #expect(inputs.ttlSeconds as Int? == nil)
        #expect(inputs.leaseToken == nil)
        #expect(inputs.expectedRevision == nil)
        #expect(inputs.asset == ControlSurfaceIconAsset(
            frames: [ControlSurfaceIconFrame(svg: "<svg/>", durationMS: 100)], loop: true
        ))
    }

    @Test func fullReplacementNeedsNoPreviousCredentialsOrTTL() throws {
        var input = params()
        input["owner_id"] = .string("restarted-producer")
        let replacement = try ControlSurfaceIconParser().parse(input, clear: false)
        #expect(replacement.ownerID == "restarted-producer")
        #expect(replacement.leaseToken == nil)
        #expect(replacement.expectedRevision == nil)
        #expect(replacement.asset != nil)
    }

    @Test func legacyAssetFreeUpdatePreservesAllCredentials() throws {
        var input = params()
        input.removeValue(forKey: "asset")
        #expect(throws: ControlSurfaceIconParser.Invalid.self) {
            try ControlSurfaceIconParser().parse(input, clear: false)
        }
        let token = UUID()
        input["lease_token"] = .string(token.uuidString)
        input["expected_revision"] = .int(7)
        let renewal = try ControlSurfaceIconParser().parse(input, clear: false)
        #expect(renewal.asset == nil)
        #expect(renewal.leaseToken == token)
        #expect(renewal.expectedRevision == 7)
        input.removeValue(forKey: "expected_process_start")
        #expect(throws: ControlSurfaceIconParser.Invalid.self) {
            try ControlSurfaceIconParser().parse(input, clear: false)
        }
    }

    @Test func clearAcceptsExplicitTargetAndOwnerWithoutProcessOrAsset() throws {
        var input = params()
        input["lease_token"] = .string(UUID().uuidString)
        input["expected_revision"] = .int(1)
        for key in ["asset", "expected_agent_pid", "expected_process_start"] { input.removeValue(forKey: key) }
        let clear = try ControlSurfaceIconParser().parse(input, clear: true)
        #expect(clear.operation == .clear)
        #expect(clear.expectedAgentPID == nil)
        #expect(clear.expectedProcessStart == nil)
        #expect(clear.asset == nil)
        input["asset"] = asset()
        #expect(throws: ControlSurfaceIconParser.Invalid.self) {
            try ControlSurfaceIconParser().parse(input, clear: true)
        }
    }

    @Test(arguments: [false, true])
    func rejectsIncompleteConditionalCredentialsBeforeDispatch(clear: Bool) {
        for fields in [[], ["lease_token"], ["expected_revision"]] as [[String]] {
            if !clear && fields.isEmpty { continue }
            var input = params()
            if clear { input.removeValue(forKey: "asset") }
            if fields.contains("lease_token") { input["lease_token"] = .string(UUID().uuidString) }
            if fields.contains("expected_revision") { input["expected_revision"] = .int(1) }
            #expect(throws: ControlSurfaceIconParser.Invalid.self) {
                try ControlSurfaceIconParser().parse(input, clear: clear)
            }
        }
    }

    @Test(arguments: ["workspace_id", "surface_id"])
    func rejectsMissingOrInvalidExplicitTargets(key: String) {
        for invalid: JSONValue? in [nil, .null, .string(""), .string("surface:1"),
                                   .string("workspace:1"), .string("current"), .int(1),
                                   .string(" " + workspaceID.uuidString),
                                   .string(workspaceID.uuidString.replacingOccurrences(of: "-", with: ""))] {
            var input = params()
            input[key] = invalid
            #expect(throws: ControlSurfaceIconParser.Invalid.self) {
                try ControlSurfaceIconParser().parse(input, clear: false)
            }
        }
    }

    @Test(arguments: ["owner_id", "expected_process_start"])
    func rejectsInvalidStringsAndUTF8Budgets(key: String) {
        let limit = key == "owner_id" ? 200 : 80
        for invalid: JSONValue? in [nil, .null, .bool(true), .string(" \n"),
                                   .string(String(repeating: "x", count: limit + 1)),
                                   .string(String(repeating: "界", count: limit / 3 + 1))] {
            var input = params()
            input[key] = invalid
            #expect(throws: ControlSurfaceIconParser.Invalid.self) {
                try ControlSurfaceIconParser().parse(input, clear: false)
            }
        }
    }

    @Test(arguments: ["focus", "surface", "workspace", "window_id", "unknown"])
    func rejectsUnknownFieldsIncludingFocusAndHandleSelectors(key: String) {
        var input = params()
        input[key] = .bool(false)
        #expect(throws: ControlSurfaceIconParser.Invalid.self) {
            try ControlSurfaceIconParser().parse(input, clear: false)
        }
    }

    @Test(arguments: ["expected_agent_pid", "expected_revision", "ttl_seconds"])
    func rejectsMalformedNumbersWithoutCoercionOrOverflow(key: String) {
        for invalid: JSONValue in [.null, .bool(true), .bool(false), .string("30"), .int(0),
                                   .int(-1), .double(1.5), .double(.infinity), .double(.nan),
                                   .double(Double(Int.max)), .decimal("9999999999999999999999999999"),
                                   .decimal("9007199254740992.5")] {
            var input = params()
            input[key] = invalid
            #expect(throws: ControlSurfaceIconParser.Invalid.self) {
                try ControlSurfaceIconParser().parse(input, clear: false)
            }
        }
    }

    @Test(arguments: [1, 4, 5, 120, 121, 600, Int.max])
    func acceptsEveryPositiveRepresentableTTL(ttl: Int) throws {
        var input = params()
        input["ttl_seconds"] = .int(Int64(ttl))
        #expect(try ControlSurfaceIconParser().parse(input, clear: false).ttlSeconds == ttl)
        input["ttl_seconds"] = .decimal(String(ttl))
        #expect(try ControlSurfaceIconParser().parse(input, clear: false).ttlSeconds == ttl)
    }

    @Test(arguments: ["1", "4", "121", "600", "600.0", "6e2", String(Int.max)])
    func acceptsTTLThroughActualJSONRequestDecoding(rawTTL: String) throws {
        let request = try decodedRequest(rawTTL: rawTTL)
        let expected = rawTTL == "600.0" || rawTTL == "6e2" ? 600 : Int(rawTTL)!
        #expect(try ControlSurfaceIconParser().parse(request.params, clear: false).ttlSeconds == expected)
    }

    @Test(arguments: ["0", "-1", "true", "null", "\"600\"", "600.5",
                      "9223372036854775808", "1e99"])
    func rejectsInvalidTTLThroughActualJSONRequestDecoding(rawTTL: String) throws {
        let request = try decodedRequest(rawTTL: rawTTL)
        #expect(throws: ControlSurfaceIconParser.Invalid.self) {
            try ControlSurfaceIconParser().parse(request.params, clear: false)
        }
    }

    @Test func heartbeatAndClearPreserveOptionalTTLTransport() throws {
        var input = params()
        input.removeValue(forKey: "asset")
        input["lease_token"] = .string(UUID().uuidString)
        input["expected_revision"] = .int(7)
        for clear in [false, true] {
            #expect(try ControlSurfaceIconParser().parse(input, clear: clear).ttlSeconds as Int? == nil)
            input["ttl_seconds"] = .int(600)
            #expect(try ControlSurfaceIconParser().parse(input, clear: clear).ttlSeconds == 600)
            input["ttl_seconds"] = .int(0)
            #expect(throws: ControlSurfaceIconParser.Invalid.self) {
                try ControlSurfaceIconParser().parse(input, clear: clear)
            }
            input.removeValue(forKey: "ttl_seconds")
        }
    }

    private func decodedRequest(rawTTL: String) throws -> ControlRequest {
        let data = try JSONSerialization.data(withJSONObject: params().mapValues(\.foundationObject))
        let encoded = String(decoding: data, as: UTF8.self)
        let line = "{\"id\":1,\"method\":\"surface.icon.set\",\"params\":"
            + encoded.dropLast() + ",\"ttl_seconds\":" + rawTTL + "}}"
        return try ControlRequestParser().request(fromLine: line).get()
    }

    @Test func rejectsMalformedLeaseTokens() {
        for invalid: JSONValue in [.null, .bool(false), .string("lease:1"), .string(""), .int(42)] {
            var input = params()
            input["lease_token"] = invalid
            #expect(throws: ControlSurfaceIconParser.Invalid.self) {
                try ControlSurfaceIconParser().parse(input, clear: false)
            }
        }
    }

    @Test func enforcesFrameCountAndSVGBudgetsAtBoundaries() throws {
        let parser = ControlSurfaceIconParser()
        var input = params()
        input["asset"] = asset(frames: Array(repeating: frame(), count: 64))
        #expect(try parser.parse(input, clear: false).asset?.frames.count == 64)
        let fullFrame = frame(svg: String(repeating: "s", count: 16 * 1024))
        input["asset"] = asset(frames: Array(repeating: fullFrame, count: 32))
        #expect(try parser.parse(input, clear: false).asset?.frames.count == 32)
        for frames in [[], Array(repeating: frame(), count: 65),
                       [frame(svg: String(repeating: "s", count: 16 * 1024 + 1))],
                       [frame(svg: String(repeating: "界", count: 5462))],
                       Array(repeating: fullFrame, count: 33)] {
            input["asset"] = asset(frames: frames)
            #expect(throws: ControlSurfaceIconParser.Invalid.self) { try parser.parse(input, clear: false) }
        }
    }

    @Test func enforcesDurationAndStaticIndexBudgets() throws {
        let parser = ControlSurfaceIconParser()
        var input = params()
        input["asset"] = asset(frames: Array(repeating: frame(duration: .int(5000)), count: 6))
        #expect(try parser.parse(input, clear: false).asset?.frames.count == 6)
        input["asset"] = asset(frames: Array(repeating: frame(duration: .int(5000)), count: 7))
        #expect(throws: ControlSurfaceIconParser.Invalid.self) { try parser.parse(input, clear: false) }
        for invalid: JSONValue in [.int(49), .int(5001), .bool(true), .double(100.5), .double(.infinity), .decimal("1e99")] {
            input["asset"] = asset(frames: [frame(duration: invalid)])
            #expect(throws: ControlSurfaceIconParser.Invalid.self) { try parser.parse(input, clear: false) }
        }
        for invalid: JSONValue in [.int(-1), .int(1), .bool(false), .double(.nan), .string("0")] {
            input["asset"] = .object(["frames": .array([frame()]), "loop": .bool(false), "static_frame": invalid])
            #expect(throws: ControlSurfaceIconParser.Invalid.self) { try parser.parse(input, clear: false) }
        }
        input["asset"] = .object([
            "frames": .array([frame(duration: .int(50)), frame()]),
            "loop": .bool(false), "static_frame": .int(1),
        ])
        #expect(try parser.parse(input, clear: false).asset?.staticFrame == 1)
    }

    @Test func rejectsMalformedAssetsAndUnknownNestedFields() {
        let malformed: [JSONValue] = [
            .null, .array([]), .bool(false),
            .object(["frames": .array([frame()])]),
            .object(["frames": .array([frame()]), "loop": .int(1)]),
            .object(["frames": .array([frame()]), "loop": .string("false")]),
            .object(["frames": .array([frame()]), "loop": .bool(true), "extra": .null]),
            asset(frames: [.null]),
            asset(frames: [.object(["svg": .string("<svg/>"), "duration_ms": .int(100), "extra": .null])]),
            asset(frames: [.object(["svg": .bool(true), "duration_ms": .int(100)])]),
            asset(frames: [.object(["svg": .string("<svg/>")])]),
        ]
        for value in malformed {
            var input = params()
            input["asset"] = value
            #expect(throws: ControlSurfaceIconParser.Invalid.self) {
                try ControlSurfaceIconParser().parse(input, clear: false)
            }
        }
    }

    @MainActor @Test func dispatchesBothEntrypointsAndPreservesRawUUIDTargets() async throws {
        let context = FakeSurfaceIconControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let input = params()
        for clear in [false, true] {
            var requestParams = input
            if clear {
                requestParams.removeValue(forKey: "asset")
                requestParams["lease_token"] = .string(UUID().uuidString)
                requestParams["expected_revision"] = .int(1)
            }
            let request = ControlRequest(
                id: .int(1), method: clear ? "surface.icon.clear" : "surface.icon.set", params: requestParams
            )
            guard case .ok(.object(let mainResult)) = coordinator.handle(request) else {
                Issue.record("main dispatch did not reach icon witness")
                return
            }
            #expect(mainResult["operation"] == .string(clear ? "clear" : "set"))
            let workerResult = await Task.detached {
                coordinator.handleSocketWorkerV2(request, context: context)
            }.value
            guard case .ok(.object(let worker)) = workerResult else {
                Issue.record("worker dispatch did not reach icon witness")
                return
            }
            #expect(worker["is_main_thread"] == .bool(false))
            #expect(worker["workspace_id"] == .string(workspaceID.uuidString))
            #expect(worker["surface_id"] == .string(surfaceID.uuidString))
            #expect(worker["ttl_seconds"] == .null)
        }
    }

    @MainActor @Test func malformedRequestFailsBeforeWitnessAndExistingFakesAreUnsupported() {
        let context = FakeSurfaceIconControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let invalid = coordinator.surfaceIcon([:], clear: false, context: context)
        guard case .err(let code, _, _) = invalid else {
            Issue.record("expected validation failure")
            return
        }
        #expect(code == "invalid_params")
        let oldContext = FakeSurfaceControlCommandContext()
        #expect(coordinator.surfaceIcon(params(), clear: false, context: oldContext) == .err(
            code: "unsupported", message: "Surface icons are not supported", data: nil
        ))
        guard case .err(let absentCode, _, _) = coordinator.surfaceIcon(params(), clear: false, context: nil) else {
            Issue.record("expected unavailable")
            return
        }
        #expect(absentCode == "unavailable")
    }
}
