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
        #expect(inputs.ttlSeconds == 30)
        #expect(inputs.leaseToken == nil)
        #expect(inputs.expectedRevision == nil)
        #expect(inputs.asset == ControlSurfaceIconAsset(
            frames: [ControlSurfaceIconFrame(svg: "<svg/>", durationMS: 100)], loop: true
        ))
    }

    @Test func renewRequiresTokenAndStillRequiresProcessIdentity() throws {
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
                                   .double(Double(Int.max)), .decimal("9999999999999999999999999999")] {
            var input = params()
            input[key] = invalid
            #expect(throws: ControlSurfaceIconParser.Invalid.self) {
                try ControlSurfaceIconParser().parse(input, clear: false)
            }
        }
    }

    @Test func acceptsTTLBoundsAndRejectsOutsideRange() throws {
        for ttl in [5, 120] {
            var input = params()
            input["ttl_seconds"] = .double(Double(ttl))
            #expect(try ControlSurfaceIconParser().parse(input, clear: false).ttlSeconds == ttl)
        }
        for ttl in [4, 121, Int64.max] {
            var input = params()
            input["ttl_seconds"] = .int(ttl)
            #expect(throws: ControlSurfaceIconParser.Invalid.self) {
                try ControlSurfaceIconParser().parse(input, clear: false)
            }
        }
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
            if clear { requestParams.removeValue(forKey: "asset") }
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
            #expect(worker["ttl_seconds"] == .int(30))
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
