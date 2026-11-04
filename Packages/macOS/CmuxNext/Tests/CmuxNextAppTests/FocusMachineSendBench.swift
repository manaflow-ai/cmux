import CmuxNextFocus
import Darwin
import Foundation
import Testing

/// R-INPUT S2 acceptance ("focus bench within 5 %"), never merged: the time of one `FocusMachine.send` (a focus event's
/// reduction and its reply read) and of one topology change, before and after S2b step B (#35875: the machine moved
/// from its own `cmux_focus_*` handle to the app's `cmux_input_*` router). The same file runs on both commits: it uses
/// only `FocusMachine()` and `send(_:into:)`, which both have. Timing runs only with CMUX_FOCUS_SEND_BENCH=1; it prints
/// one `FOCUS-SEND-BENCH {json}` line per kind (ns per call: p50, p95, p99, max, over rounds of a fixed sequence).
@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CMUX_FOCUS_SEND_BENCH"] == "1"))
struct FocusMachineSendBench {
    private static func topology(_ panes: Int, selected: Int) -> FocusTopology {
        FocusTopology(workspace: "w", panes: (0..<panes).map { index in
            .init(id: "p\(index)", tabs: [.init(id: "t\(index)", kind: index % 3 == 2 ? .browser : .terminal),
                                         .init(id: "u\(index)", kind: .terminal)],
                  selected: index == selected ? "u\(index)" : "t\(index)")
        })
    }

    private static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    private static func summary(_ name: String, _ samples: [UInt64]) -> String {
        let sorted = samples.sorted()
        func at(_ q: Double) -> UInt64 { sorted[min(sorted.count - 1, max(0, Int((q * Double(sorted.count)).rounded(.up)) - 1))] }
        return "FOCUS-SEND-BENCH {\"kind\":\"\(name)\",\"n\":\(sorted.count),\"p50_ns\":\(at(0.5)),\"p95_ns\":\(at(0.95)),\"p99_ns\":\(at(0.99)),\"max_ns\":\(sorted.last ?? 0)}"
    }

    @Test func focusSendBench() {
        let machine = FocusMachine()
        var state = FocusState()
        _ = machine.send(.topology(Self.topology(30, selected: 0)), into: &state)
        let events: [FocusEvent] = (0..<30).flatMap { index -> [FocusEvent] in
            [.focusPane("p\(index)", source: .mouse),
             .selectTab(pane: "p\(index)", tab: "u\(index)", workspace: "w", source: .keyboard),
             .responder(.content(pane: "p\(index)"), source: .mouse)]
        }
        for event in events { _ = machine.send(event, into: &state) } // warm-up
        var sends: [UInt64] = []
        sends.reserveCapacity(events.count * 200)
        for _ in 0..<200 {
            for event in events {
                let start = Self.now()
                _ = machine.send(event, into: &state)
                sends.append(Self.now() &- start)
            }
        }
        var topologies: [UInt64] = []
        topologies.reserveCapacity(2000)
        for round in 0..<2000 {
            let topology = Self.topology(30, selected: round % 30)
            let start = Self.now()
            _ = machine.send(.topology(topology), into: &state)
            topologies.append(Self.now() &- start)
        }
        print(Self.summary("send", sends))
        print(Self.summary("topology", topologies))
        #expect(!sends.isEmpty && !topologies.isEmpty)
    }
}
