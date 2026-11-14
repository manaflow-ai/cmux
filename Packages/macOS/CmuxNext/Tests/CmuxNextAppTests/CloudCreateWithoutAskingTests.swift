import AppKit
@testable import CmuxNextApp
import CmuxNextAppCore
import CmuxNextCloud
import CmuxNextSettings
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// The plan gate a create reads from the last machine list's limits.
@MainActor struct CloudCreateWithoutAskingTests {
    @Test func gateReadsThePlanLimits() {
        #expect(CloudMachineCreateFlow.gate(nil) == .allowed, "unknown limits must leave the server to decide")
        #expect(CloudMachineCreateFlow.gate(.init(maxActiveVms: 5, activeVmCount: 1, planId: "pro")) == .allowed)
        #expect(CloudMachineCreateFlow.gate(.init(maxActiveVms: 0, activeVmCount: 0, planId: "free")) == .upgrade(.init(reason: .freePlan)))
        #expect(CloudMachineCreateFlow.gate(.init(maxActiveVms: nil, activeVmCount: 0, planId: "free")) == .upgrade(.init(reason: .freePlan)))
        #expect(CloudMachineCreateFlow.gate(.init(maxActiveVms: 2, activeVmCount: 2, planId: "go")) == .upgrade(.init(reason: .atLimit(2))))
        // The app-server link's backend pauses the person's idle machine at the cap itself: the create goes out.
        #expect(CloudMachineCreateFlow.gate(.init(maxActiveVms: 2, activeVmCount: 2, planId: "go"), makesRoom: true) == .allowed)
        #expect(CloudMachineCreateFlow.gate(.init(maxActiveVms: 0, activeVmCount: 0, planId: "free"), makesRoom: true) == .upgrade(.init(reason: .freePlan)))
    }
}
