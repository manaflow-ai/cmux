#if DEBUG || CMUX_BENCH_HOOKS
@testable import CmuxNextControl
import CmuxNextSettings
import CmuxNextTrace
import Testing

/// `debug.hang_inject` reads lane, ms and action, refuses anything else, and arms, lists and disarms a lane of
/// the hang watch it was given (p09-observability-088).
@Suite
struct HangInjectControlTests {
    @Test func requestsReadTheirInputsAndRefuseOthers() throws {
        #expect(try HangInjectControl.request(["lane": .string("daemon.line")]) == .arm(lane: "daemon.line", hang: .seconds(3)))
        #expect(try HangInjectControl.request(["lane": .string("lane.files"), "ms": .number(8_500)])
            == .arm(lane: "lane.files", hang: .milliseconds(8_500)))
        #expect(try HangInjectControl.request(["lane": .string("main"), "ms": .number(5_000)]) == .hangMain(.seconds(5)))
        #expect(try HangInjectControl.request(["action": .string("disarm")]) == .disarm)
        #expect(try HangInjectControl.request(["action": .string("list")]) == .list)
        let refused: [[String: JSONValue]] = [
            [:],
            ["lane": .string("x"), "ms": .number(0)],
            ["lane": .string("x"), "ms": .number(30_001)],
            ["lane": .string("x"), "path": .string("/tmp")],
            ["action": .string("list"), "lane": .string("x")],
            ["action": .string("crash")],
        ]
        for params in refused {
            #expect(throws: ControlError.self) { try HangInjectControl.request(params) }
        }
    }

    @MainActor @Test func anArmIsListedAndDisarmed() throws {
        let watch = HangWatch()
        _ = watch.registerLane("test.control")
        let armed = try HangInjectControl.run(.arm(lane: "test.control", hang: .seconds(3)), on: watch)
        #expect(armed.objectValue?["armed"]?.stringValue == "test.control")
        #expect(armed.objectValue?["ms"]?.intValue == 3_000)
        #expect(armed.objectValue?["lanes"]?.arrayValue?.compactMap(\.stringValue) == ["main", "test.control"])
        #expect(throws: ControlError.self) { try HangInjectControl.run(.arm(lane: "test.missing", hang: .seconds(1)), on: watch) }

        let disarmed = try HangInjectControl.run(.disarm, on: watch)
        #expect(disarmed.objectValue?["disarmed"]?.stringValue == "test.control")
        #expect(disarmed.objectValue?["armed"] == .null)
    }
}
#endif
