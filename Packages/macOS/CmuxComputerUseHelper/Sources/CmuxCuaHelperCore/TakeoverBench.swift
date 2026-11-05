// SPDX-License-Identifier: GPL-3.0-or-later
import ApplicationServices
import AppKit
import Darwin
import Foundation

/// `cmux-cua-helper --takeover-bench [--events N]` measures the takeover
/// detector on a real window server, under the helper's own grants:
///
/// - False takeovers under agent input: this process posts N harmless events
///   (a zero scroll, an in-place pointer move, F19 down and up) on each route
///   Cua Driver uses, and counts any the tap took for the person.
/// - Detection latency: a second copy of this executable
///   (`--takeover-bench-person N`) posts N zero scrolls 20 ms apart, each
///   stamped with its post time, and this process times post -> tap callback.
///
/// It prints one JSON object and exits 0, or 2 when the tap could not start.
public struct TakeoverBench {
    public static let flag = "--takeover-bench"
    static let personFlag = "--takeover-bench-person"

    public init() {}

    /// F19: no default binding on macOS.
    static let harmlessKey: CGKeyCode = 80

    public func main(arguments: [String]) -> Int32 {
        if let index = arguments.firstIndex(of: Self.personFlag) {
            let count = arguments.dropFirst(index + 1).first.flatMap { Int($0) } ?? 200
            Self.postAsPerson(count: count)
            return 0
        }
        let count = arguments.firstIndex(of: "--events").flatMap { arguments.dropFirst($0 + 1).first }
            .flatMap { Int($0) } ?? 500
        return Self.run(events: count)
    }

    enum Route: String, CaseIterable {
        /// Marked like everything cmux posts itself.
        case markedHID = "marked_hid"
        /// Unmarked at the HID tap from this process: Cua Driver's global key and interactive routes.
        case unmarkedHID = "unmarked_hid"
        /// Unmarked to one pid: Cua Driver's background route (CGEventPostToPid).
        case postToPid = "post_to_pid"
    }

    static func run(events: Int) -> Int32 {
        let tap = TakeoverTap(trusted: { true })
        tap.ensureStarted()
        guard waitUntil(seconds: 3, { tap.gate.holder() != .unwatched }) else {
            print(json(["ok": false, "error": "tap unavailable or provenance not proven",
                        "ax_trusted": AXIsProcessTrusted()]))
            return 2
        }
        let target = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.finder" }?
            .processIdentifier
        var routes: [String: Any] = [:]
        for route in Route.allCases {
            let before = tap.gate.snapshot()
            var posted = 0
            for _ in 0..<events {
                posted += post(route: route, pid: target)
                usleep(2_000)
            }
            settle()
            let after = tap.gate.snapshot()
            routes[route.rawValue] = [
                "posted": posted,
                "seen_as_agent": after.agentEvents - before.agentEvents,
                "seen_as_person": after.personEvents - before.personEvents,
                "false_takeovers": after.takeovers - before.takeovers,
            ]
        }
        let stats = tap.gate.snapshot()

        // Quiet so the person's first event is a takeover from the agent.
        Thread.sleep(forTimeInterval: tap.gate.rule.quiet.totalSeconds + 0.1)
        _ = tap.takeStampedLatencies()
        let personEvents = max(50, events / 2)
        let takeoversBefore = tap.gate.snapshot().takeovers
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = [personFlag, String(personEvents)]
        var latencies: [UInt64] = []
        do {
            try child.run()
            child.waitUntilExit()
            settle()
            latencies = tap.takeStampedLatencies().sorted()
        } catch {
            print(json(["ok": false, "error": "person process did not start: \(error)"]))
            return 2
        }
        tap.stop()
        let ms = { (value: UInt64) in Double(value) / 1_000_000 }
        func pct(_ p: Double) -> Double? {
            latencies.isEmpty ? nil : ms(latencies[min(latencies.count - 1, Int(Double(latencies.count) * p))])
        }
        print(json([
            "ok": true,
            "host": ProcessInfo.processInfo.hostName,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "agent": [
                "events_per_route": events,
                "routes": routes,
                "false_takeovers": stats.takeovers,
                "false_takeover_rate": Double(stats.personEvents) / Double(max(1, stats.agentEvents + stats.personEvents)),
            ],
            "person": [
                "posted": personEvents,
                "seen": latencies.count,
                "takeovers": tap.gate.snapshot().takeovers - takeoversBefore,
                "detect_ms_p50": pct(0.50) ?? NSNull(),
                "detect_ms_p95": pct(0.95) ?? NSNull(),
                "detect_ms_p99": pct(0.99) ?? NSNull(),
                "detect_ms_max": latencies.last.map(ms) ?? NSNull(),
            ],
        ]))
        return 0
    }

    /// Post one harmless event pattern on `route`; returns how many events it posted.
    static func post(route: Route, pid: pid_t?) -> Int {
        let source = CGEventSource(stateID: .hidSystemState)
        if route == .markedHID { source?.userData = TakeoverMarker.value }
        let here = CGEvent(source: nil)?.location ?? .zero
        let events = [
            CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 1, wheel1: 0, wheel2: 0, wheel3: 0),
            CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: here, mouseButton: .left),
            CGEvent(keyboardEventSource: source, virtualKey: harmlessKey, keyDown: true),
            CGEvent(keyboardEventSource: source, virtualKey: harmlessKey, keyDown: false),
        ].compactMap { $0 }
        for event in events {
            if route == .postToPid, let pid { event.postToPid(pid) } else { event.post(tap: .cghidEventTap) }
        }
        return events.count
    }

    static func postAsPerson(count: Int) {
        let source = CGEventSource(stateID: .hidSystemState)
        for _ in 0..<count {
            guard let event = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 1,
                                      wheel1: 0, wheel2: 0, wheel3: 0) else { continue }
            event.setIntegerValueField(.eventSourceUserData, value: TakeoverTap.benchStamp(nanos: TakeoverGate.uptimeNanos()))
            event.post(tap: .cghidEventTap)
            usleep(20_000)
        }
    }

    static func settle() { Thread.sleep(forTimeInterval: 0.3) }

    static func waitUntil(seconds: Double, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return condition()
    }

    static func json(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

extension Duration {
    var totalSeconds: Double { Double(totalNanos) / 1_000_000_000 }
}
