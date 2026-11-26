import Foundation
import Observation
import Testing
@testable import CmuxWorkspaces

/// #15439: reading `WorkspacesModel` members must cost about what reading a
/// non-generic `@Observable` property costs, tracked or not.
///
/// The Sentry hangs sat in these getters because `@Observable` on a generic
/// class builds a fresh generic key path (`\WorkspacesModel<Tab>.tabs`) on
/// every read, and a tracked read then hashes its generic arguments into the
/// access list. SwiftUI bodies, overlay refreshes and `selectedWorkspace`
/// read these members many times per update, so the per-read cost is the
/// regression oracle. Comparing against a control measured in the same
/// process keeps the bound independent of machine speed.
@MainActor
@Suite(.serialized)
struct WorkspacesModelReadCostTests {
    /// Before #15439 the generic reads cost about 1 µs each in the debug
    /// package lane, 6.7x to 10.6x the control, and 70x to 150x in an
    /// optimized build. The paired ratio is independent of absolute machine
    /// speed, so keep a generous regression bound while avoiding a wall-clock
    /// assertion that would be sensitive to scheduler preemption.
    private static let readsPerTrial = 4_000
    private static let trials = 9

    @Test(arguments: WorkspacesModelReadCostMember.allCases, [true, false])
    func readCostMatchesNonGenericObservableControl(_ member: WorkspacesModelReadCostMember, tracked: Bool) {
        let model = WorkspacesModel<ReadCostStubTab>()
        let control = NonGenericWorkspacesControl()
        let tab = ReadCostStubTab()
        model.tabs = [tab]
        control.tabs = [tab]
        model.selectedTabId = tab.id
        control.selectedTabId = tab.id

        let modelRead: () -> Int
        let controlRead: () -> Int
        switch member {
        case .tabs:
            modelRead = { model.tabs.count }
            controlRead = { control.tabs.count }
        case .workspaceGroups:
            modelRead = { model.workspaceGroups.count }
            controlRead = { control.workspaceGroups.count }
        case .selectedTabId:
            modelRead = { model.selectedTabId == nil ? 0 : 1 }
            controlRead = { control.selectedTabId == nil ? 0 : 1 }
        }

        // Interleave the two so drift in machine load hits both, and keep
        // each side's fastest trial.
        var modelNanoseconds = Double.infinity
        var controlNanoseconds = Double.infinity
        for _ in 0..<Self.trials {
            controlNanoseconds = min(controlNanoseconds, Self.nanosecondsPerRead(tracked: tracked, controlRead))
            modelNanoseconds = min(modelNanoseconds, Self.nanosecondsPerRead(tracked: tracked, modelRead))
        }

        let ratio = modelNanoseconds / controlNanoseconds
        #expect(
            ratio < 3.0,
            "generic WorkspacesModel read is \(ratio)× the non-generic control"
        )
        print(
            "WorkspacesModelReadCost member=\(member.rawValue) tracked=\(tracked) "
                + "model_ns=\(Self.format(modelNanoseconds, unit: "")) "
                + "control_ns=\(Self.format(controlNanoseconds, unit: "")) "
                + "ratio=\(Self.format(ratio, unit: ""))"
        )
    }

    private static func nanosecondsPerRead(tracked: Bool, _ read: () -> Int) -> Double {
        var sink = 0
        let elapsed = ContinuousClock().measure {
            if tracked {
                withObservationTracking({
                    for _ in 0..<readsPerTrial { sink &+= read() }
                }, onChange: {})
            } else {
                for _ in 0..<readsPerTrial { sink &+= read() }
            }
        }
        withExtendedLifetime(sink) {}
        let nanoseconds = Double(elapsed.components.seconds) * 1e9
            + Double(elapsed.components.attoseconds) / 1e9
        return nanoseconds / Double(readsPerTrial)
    }

    private static func format(_ value: Double, unit: String = " ns/read") -> String {
        String(format: "%.1f", value) + unit
    }
}
