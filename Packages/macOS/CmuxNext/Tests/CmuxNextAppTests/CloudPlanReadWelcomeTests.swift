import CmuxNextActions
import CmuxNextCloud
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextHomeEngine
import CmuxNextWakeups
import Foundation
import Testing
@testable import CmuxNextApp

/// Leo, 2026-11-23: "you guys need to be absolutely exhaustively testing out what would a new user be
/// seeing here? And in terms of like a new pro user, how would they do it?" A person who had just paid
/// saw nothing change in the app: the plan read stored the limits and never told ``CloudService/planObserved``,
/// the only thing the "Welcome to cmux Pro" card listens to.
@MainActor struct CloudPlanReadWelcomeTests {
    private static func cloud(_ machines: MachineRegistry = MachineRegistry(local: DaemonService())) -> CloudService {
        let origin = URL(string: "https://backend.standin.invalid")!
        let bundle = "com.cmuxterm.next.dev.plan-read-\(UUID().uuidString.lowercased())"
        let selection = CloudRuntimeSelection(name: "staging", apiOrigin: origin, authWebOrigin: origin, vmOrigin: origin,
            platformOrigin: origin, mobileOrigin: origin, deviceHubOrigin: origin, shareRoomOrigin: origin, shareApiOrigin: origin,
            stackOrigin: origin, stackProjectId: "staging-project", stackClientKey: "staging-key", bundleId: bundle,
            mutable: true, authNamespace: "staging-2", legacyStorage: false)
        let configuration = CloudConfiguration.from(selection: selection, bundleID: bundle, bundled: [:], process: [:], isDebugBuild: true)
        return CloudService(machines: machines, isDebugBuild: true,
                            mainWork: MainWorkScheduler(budget: MainFrameBudget()), work: BackgroundWork(),
                            loginKeychain: LoginKeychain(), configuration: configuration)
    }

    private static func answer(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    @Test func aPlanTheAppReadsReachesTheWelcomeStep() throws {
        let machines = MachineRegistry(local: DaemonService())
        let cloud = Self.cloud(machines)
        var observed: [String?] = []
        cloud.planObserved = { observed.append($0) }

        cloud.planRead(try Self.answer(#"{"plan_id":"none","limits":{"max_active":0},"usage":{"active":0}}"#))
        cloud.planRead(try Self.answer(#"{"plan_id":"pro","upgrade_plan":"max","limits":{"max_active":3,"max_saved":10,"memory_options_mb":[4096],"locked_memory_options_mb":[]},"usage":{"active":1,"saved":0,"period_end":0}}"#))

        #expect(observed == ["free", "pro"])
        #expect(machines.cloudLimits?.planId == "pro")
    }

    /// An answer that names no plan is no answer: it reports nothing, so a blip never reads as a downgrade.
    @Test func anAnswerWithoutAPlanReportsNone() throws {
        let cloud = Self.cloud()
        var observed: [String?] = []
        cloud.planObserved = { observed.append($0) }
        cloud.planRead(try Self.answer(#"{"limits":{"max_active":3}}"#))
        #expect(observed.isEmpty)
    }
}
