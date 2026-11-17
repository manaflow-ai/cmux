import CmuxNextCloud
import CmuxNextDaemon
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Cloud plans and machine sizes on the page: the plan the page reads before Send (only the server's "no plan" gates),
/// the start's plan and size refusals, the pricing card's Subscribe (Pro or Max only, on a click) and a GitHub
/// repository's size from the repos list.
@MainActor
struct AgentPaneCloudPlanTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    @Test func thePlanIsUnknownUnlessTheServerAnswered() async throws {
        typealias Plan = AgentPaneCloudMachines.Plan
        #expect(Plan(planGet: nil) == .unknown)
        // An older server: no plan_state, never gates.
        #expect(Plan(planGet: .object(["plan_id": .string("none"), "max_size": .null])) == .unknown)
        #expect(Plan(planGet: .object(["plan_state": .string("none"), "plan_id": .null, "max_size": .null])) == .init(state: .noPlan))
        #expect(Plan(planGet: .object(["plan_state": .string("unknown"), "plan_id": .string("x")])) == .unknown)
        let pro = Plan(planGet: .object(["plan_state": .string("active"), "plan_id": .string("pro"), "max_size": .string("lg")]))
        #expect(pro == .init(state: .active, id: "pro", maxSize: .lg))
        #expect(Plan(planGet: .object(["plan_state": .string("active"), "plan_id": .string("max"), "max_size": .string("2xl")])).maxSize == .xxl)

        // Read at most once per age for one account; a failed read is unknown and not kept; another account reads again.
        var reads = 0
        let get = { () async throws -> JSONValue in reads += 1; return .object(["plan_state": .string("active"), "plan_id": .string("pro"), "max_size": .string("lg")]) }
        let start = ContinuousClock.now, me: [String?] = ["u-plan-\(UUID().uuidString)", nil]
        #expect(await Plan.read(account: nil, now: start, get) == .unknown && reads == 0)
        #expect(await Plan.read(account: me, now: start) { throw CancellationError() } == .unknown)
        #expect(await Plan.read(account: me, now: start, get) == pro && reads == 1)
        #expect(await Plan.read(account: me, now: start + .seconds(30), get) == pro && reads == 1)
        #expect(await Plan.read(account: me, now: start + .seconds(61), get) == pro && reads == 2)
        #expect(await Plan.read(account: ["someone-else", nil], now: start + .seconds(62), get) == pro && reads == 3)

        let machines = AgentPaneCloudMachines()
        machines.list = { .init(signedIn: true, loaded: true, machines: [], plan: pro) }
        let value = try #require(await AgentPaneCloudMachineRequest.list.reply(machines, gestures: AgentPaneUserGestures())["value"] as? [String: Any])
        let plan = try #require(value["plan"] as? [String: Any])
        #expect(plan["state"] as? String == "active" && plan["id"] as? String == "pro" && plan["max_size"] as? String == "lg")
        // Signed out: unknown, whatever was cached.
        machines.list = { .init(signedIn: false, loaded: false, machines: [], plan: .init(state: .noPlan)) }
        let out = try #require(await AgentPaneCloudMachineRequest.list.reply(machines, gestures: AgentPaneUserGestures())["value"] as? [String: Any])
        let unknown = try #require(out["plan"] as? [String: Any])
        #expect(unknown["state"] as? String == "unknown" && unknown["id"] is NSNull && unknown["max_size"] is NSNull)
    }

    @Test func theRefusalsCarryWhatTheCardOffers() throws {
        let required = AgentPaneCloudPlanRefusal.planRequiredDetails(["teams": [[String: String]](), "canSwitch": false])
        #expect(required["plans"] as? [String] == ["pro", "max"] && required["canSwitch"] as? Bool == false)

        let reply = CloudSizeLocked(upgradePlan: "max", upgradeNamed: true, needed: .xl, folderBytes: 123).reply(planMax: nil)
        let error = try #require(reply["error"] as? [String: Any])
        #expect(error["code"] as? String == "cloud_size_locked" && error["retryable"] as? Bool == true)
        let details = try #require(error["details"] as? [String: Any])
        #expect(details["needed"] as? String == "xl" && details["allowed"] as? String == "lg")
        #expect(details["upgrade_plan"] as? String == "max" && details["folder_bytes"] as? Int64 == 123)
        let top = try #require(CloudSizeLocked(upgradeNamed: true, needed: .xl).reply(planMax: .xl)["error"] as? [String: Any])
        #expect((top["details"] as? [String: Any])?["upgrade_plan"] is NSNull)
    }

    @Test func subscribeTakesProOrMaxOnAClick() async {
        #expect(AgentPaneRequest(body: ["method": "cloud.plan.subscribe", "params": ["plan": "max"]]) == .cloudPlanSubscribe(plan: "max"))
        for refused: [String: Any] in [["plan": "team"], ["plan": "Pro"], ["plan": 1], [:]] {
            #expect(AgentPaneRequest(body: ["method": "cloud.plan.subscribe", "params": refused]) == .unsupported("cloud.plan.subscribe"))
        }
        #expect(AgentPageOps.methods["cloud.plan.subscribe"] == "cloud.plan.subscribe")

        let model = AgentPaneModel(host: NoHost())
        var ran: [(String, [String: String])] = []
        model.onRunAction = { id, arguments in ran.append((id, arguments)); return .ran }
        #expect(await model.respond(to: .cloudPlanSubscribe(plan: "pro"))["ok"] as? Bool != true)
        #expect(ran.isEmpty, "no click, no checkout")
        model.transport.gestures.record()
        let opened = await model.respond(to: .cloudPlanSubscribe(plan: "max"))
        #expect((opened["value"] as? [String: Any])?["opened"] as? Bool == true)
        #expect(ran.map(\.0) == ["palette.pro.upgrade"] && ran.first?.1 == ["source": "cloudRefusal", "plan": "max"])
    }

    @Test func aRepositoryStartIsSizedFromTheReposList() throws {
        AgentPaneGitHubRepoSizes.note([.init(fullName: "acme/Big", isPrivate: true, defaultBranch: nil, sizeKb: 10 * 1_048_576),
                                       .init(fullName: "acme/small", isPrivate: true, defaultBranch: nil)])
        var start = AgentPaneCloudStart(task: "t", cwd: nil, key: UUID().uuidString)
        start.repository = "acme/big"
        let big = try start.sizedForRepository()
        #expect(big.size == .md && big.folderBytes == 10 * 1_073_741_824)
        start.repository = "acme/small"
        #expect(try start.sizedForRepository().size == .sm)
        start.repository = nil
        #expect(try start.sizedForRepository() == start)
    }
}
