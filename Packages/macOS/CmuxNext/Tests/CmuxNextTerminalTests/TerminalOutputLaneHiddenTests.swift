import CmuxNextCompat
@testable import CmuxNextTerminal
import Dispatch
import Foundation
import GhosttyNextKit
import Testing

/// A hidden surface's output lane: with feature `terminalStreamPriority` on (`lowersHidden`) its
/// parses run at utility, so a hidden printer never competes with the shown terminal's echo, and shown again
/// they run at user-interactive. Order never changes: hidden and shown chunks parse in the order they were
/// queued. With the feature off every parse runs at user-interactive, hidden or not.
@Suite(.timeLimit(.minutes(1))) struct TerminalOutputLaneHiddenTests {
    static let surface = TerminalOutputLaneHangScopeTests.surface

    @Test func withTheFeatureOffHiddenParsesKeepUserInteractive() async {
        let parses = ParseLog()
        let lane = TerminalOutputLane(surface: Self.surface, label: "test.terminal-hidden-off") { _, data in
            parses.append(String(decoding: data, as: UTF8.self), qos: qos_class_self())
        }
        defer { lane.close {} }
        lane.setHidden(true)
        lane.processOutput(Data("hidden".utf8))
        await lane.drained()
        lane.setHidden(false)
        lane.processOutput(Data("shown".utf8))
        await lane.drained()

        #expect(parses.names == ["hidden", "shown"])
        #expect(parses.qos(of: "hidden") == QOS_CLASS_USER_INTERACTIVE)
        #expect(parses.qos(of: "shown") == QOS_CLASS_USER_INTERACTIVE)
    }

    @Test func hiddenParsesRunAtUtilityAndKeepTheirOrder() async {
        let parses = ParseLog()
        let lane = TerminalOutputLane(surface: Self.surface, label: "test.terminal-hidden", lowersHidden: true) { _, data in
            parses.append(String(decoding: data, as: UTF8.self), qos: qos_class_self())
        }
        defer { lane.close {} }
        // Drained between phases: a shown chunk queued behind a hidden one would raise it (an override).
        lane.processOutput(Data("shown".utf8))
        await lane.drained()
        lane.setHidden(true)
        lane.processOutput(Data("hidden".utf8))
        await lane.drained()
        lane.setHidden(false)
        lane.processOutput(Data("again".utf8))
        await lane.drained()

        #expect(parses.names == ["shown", "hidden", "again"])
        #expect(parses.qos(of: "hidden") == QOS_CLASS_UTILITY)
        #expect(parses.qos(of: "shown") == QOS_CLASS_USER_INTERACTIVE)
        #expect(parses.qos(of: "again") == QOS_CLASS_USER_INTERACTIVE)
    }
}

/// Each parsed chunk with the QoS of the thread that parsed it, in order.
nonisolated private final class ParseLog: Sendable {  // appended to on the output lane
    private let entries = Mutex<[(name: String, qos: qos_class_t)]>([])
    var names: [String] { entries.withLock { $0.map(\.name) } }
    func qos(of name: String) -> qos_class_t? { entries.withLock { $0.first { $0.name == name }?.qos } }
    func append(_ name: String, qos: qos_class_t) { entries.withLock { $0.append((name, qos)) } }
}
