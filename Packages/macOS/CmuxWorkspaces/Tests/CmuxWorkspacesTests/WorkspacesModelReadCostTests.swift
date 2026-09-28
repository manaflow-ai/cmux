import Foundation
import Observation
import Testing
@testable import CmuxWorkspaces

@MainActor
private final class ReadCostStubTab: WorkspaceTabRepresenting {
    let id = UUID()
    var groupId: UUID?
    var isPinned = false
    var currentDirectory = "/tmp"
}

/// The same three stored members on a non-generic `@Observable` class: the
/// per-read cost SwiftUI pays for an ordinary observable property.
@MainActor
@Observable
private final class NonGenericWorkspacesControl {
    var tabs: [ReadCostStubTab] = []
    var workspaceGroups: [WorkspaceGroup] = []
    var selectedTabId: UUID?
}

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
    enum Member: String, CaseIterable, Sendable {
        case tabs
        case workspaceGroups
        case selectedTabId
    }

    /// Before #15439 the generic reads measured 70x to 150x the control; a
    /// fixed model measures within 2x. The bound sits well clear of both.
    private static let maximumCostRatio = 5.0
    private static let readsPerTrial = 4_000
    private static let trials = 9

    @Test(arguments: Member.allCases, [true, false])
    func readCostMatchesNonGenericObservableControl(_ member: Member, tracked: Bool) {
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
            ratio <= Self.maximumCostRatio,
            """
            WorkspacesModel.\(member.rawValue) \(tracked ? "tracked" : "untracked") read: \
            \(Self.format(modelNanoseconds)) vs non-generic control \(Self.format(controlNanoseconds)) \
            (\(Self.format(ratio, unit: "x")))
            """
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
