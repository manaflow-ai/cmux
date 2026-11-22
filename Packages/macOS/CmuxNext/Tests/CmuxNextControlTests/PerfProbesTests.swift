@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import Testing

/// `perf.*` (`cmux perf profile --frames`) measures the person's own Release or NIGHTLY app: registered outside
/// every `#if`, never named `debug.*` (a Release router drops those), off by default, and while off every probe
/// answers `perf.probes_disabled` and runs nothing.
@MainActor
@Suite struct PerfProbesTests {
    /// Each probe call by method name, with its `action`.
    private final class Calls { var log: [String] = [] }

    private func probes(_ calls: Calls) -> PerfProbes {
        func probe(_ name: String) -> PerfProbes.Probe {
            { params in
                calls.log.append("\(name) \(params["action"]?.stringValue ?? "read")")
                return ["sources": ["x.swift:1": 1], "count": 1]
            }
        }
        return PerfProbes(watchdog: MainThreadWatchdog(configuration: .init(threshold: .milliseconds(50), logStalls: false, hangAssertThreshold: nil)),
                          frames: probe("frames"), layoutCounters: probe("layout"), tabSwitch: probe("tab"), workspaceSwitch: probe("workspace"))
    }

    private func code(_ body: () throws -> Any) -> String? {
        do { _ = try body(); return nil } catch let error as ControlError { return error.code } catch { return "other" }
    }

    @Test func offByDefault() {
        let probes = probes(Calls())
        #expect(!probes.gate.isEnabled)
        #expect(probes.status == ["enabled": false, "expires_in_s": 0])
    }

    @Test func everyProbeRefusesWhileOffAndRunsNothing() {
        let calls = Calls()
        let probes = probes(calls)
        for name in PerfProbes.gatedMethods where name != "perf.hangs" {
            #expect(code { try probes.handle(name, ["action": "start"]) } == PerfProbes.disabledCode)
        }
        #expect(code { try PerfProbes.hangs(gate: probes.gate, watchdog: MainThreadWatchdog()) } == PerfProbes.disabledCode)
        #expect(calls.log.isEmpty)
        #expect(PerfProbes.disabledError("perf.frames").message.contains(PerfProbes.enableMethod))
    }

    @Test func onAnswersAndOffStopsWhatItStarted() throws {
        let calls = Calls()
        let probes = probes(calls)
        let on = try probes.enable(["on": true, "ttl_s": 30])
        #expect(on["enabled"] == true)
        #expect((on["expires_in_s"]?.doubleValue ?? 0) > 0)
        _ = try probes.handle("perf.frames", ["action": "start"])
        _ = try probes.handle("perf.tab_switch", [:])
        let counters = try probes.handle("perf.layout_counters", [:])
        #expect(counters["sources"] == nil) // call sites stay out of the reply
        #expect(counters["count"] == 1)
        let hangs = try PerfProbes.hangs(gate: probes.gate, watchdog: MainThreadWatchdog())
        #expect(hangs["records"] == nil) // counters only, never stacks
        #expect(hangs["frames_over_8_3ms"] != nil)
        _ = try probes.enable(["on": false])
        #expect(!probes.gate.isEnabled)
        // Off stops the frames recording it started, and nothing it did not start (a debug.* bench's own).
        #expect(calls.log == ["frames start", "tab read", "layout read", "frames stop"])
        #expect(code { try probes.handle("perf.frames", [:]) } == PerfProbes.disabledCode)
    }

    @Test func enableValidatesItsParams() {
        let probes = probes(Calls())
        #expect(code { try probes.enable(["on": "yes"]) } == "invalid_params")
        for bad: JSONValue in [0, 3_601, .number(2.5), "10"] {
            #expect(code { try probes.enable(["on": true, "ttl_s": bad]) } == "invalid_params")
        }
        #expect(!probes.gate.isEnabled)
        #expect(code { try probes.enable([:]) } == nil) // no `on`: a read
        #expect(!probes.gate.isEnabled)
    }

    @Test func methodsAreNotDebugMethodsSoReleaseKeepsThem() {
        let names = probes(Calls()).methods().map(\.name)
        #expect(names == [PerfProbes.enableMethod] + PerfProbes.gatedMethods)
        #expect(names.allSatisfy { !ControlRouter.isDebugMethod($0) })
    }

    @Test func appControlRegistersThemOutsideEveryIf() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Sources/CmuxNextApp/Control/AppControl.swift"), encoding: .utf8)
        var depth = 0
        var registrations = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("#if ") { depth += 1 } else if line == "#endif" { depth -= 1 }
            guard line.contains("register(perfProbes.methods())") else { continue }
            registrations += 1
            #expect(depth == 0, "AppControl.swift registers perf.* inside an #if: \(line)")
        }
        #expect(registrations == 1)
    }
}
