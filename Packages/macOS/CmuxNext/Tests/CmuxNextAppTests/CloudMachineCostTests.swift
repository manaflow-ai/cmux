import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextCloud
import CmuxNextDaemon
@testable import CmuxNextSidebar
import Foundation
import Testing

/// The sidebar's strings; the app module has its own `Strings`.
private typealias SidebarStrings = CmuxNextSidebar.Strings

/// A Cloud machine's cost line (pilot blocker 1b): the rate of its size,
/// how long it has run and the estimate so far, from server facts only, and
/// the account's cap from `limits` (null is no cap, zero is closed; never
/// inferred from the machine list, #16012).
@MainActor @Suite(.serialized) struct CloudMachineCostTests {
    private static let enUS = Locale(identifier: "en_US")
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func machine(_ status: CloudMachine.Status, rate: Double? = 0.2645, runningFor seconds: TimeInterval? = 8_040) -> CloudMachine {
        var machine = CloudMachine(id: "vm-cost", status: status, displayName: "api")
        machine.hourlyRateUsd = rate
        machine.runningSince = seconds.map { now.addingTimeInterval(-$0) }
        return machine
    }

    // MARK: Rate and estimate formatting

    @Test func rateAndDurationFormatToTheCentAndTwoUnits() {
        #expect(SidebarMachine.Cost.price(0.2645, locale: Self.enUS) == "$0.26")
        #expect(SidebarMachine.Cost.price(12.3456, locale: Self.enUS) == "$12.35")
        #expect(SidebarMachine.Cost.duration(8_040, locale: Self.enUS) == "2h 14m")
        #expect(SidebarMachine.Cost.duration(3 * 86_400 + 4 * 3_600 + 59, locale: Self.enUS) == "3d 4h")
        // Under a minute reads as one minute, never "0m".
        #expect(SidebarMachine.Cost.duration(12, locale: Self.enUS) == "1m")
    }

    @Test func aRunningMachineShowsRateTimeAndEstimate() throws {
        let cost = try #require(CloudCreationRows.cost(Self.machine(.running), limits: nil))
        #expect(cost.runningSeconds(now: Self.now) == 8_040)
        // 0.2645 $/h x 2h 14m = $0.5907.
        #expect(abs((cost.estimatedCostUsd(now: Self.now) ?? 0) - 0.590_716) < 0.000_01)
        #expect(cost.usage(now: Self.now, locale: Self.enUS)
            == [SidebarStrings.costRate("$0.26"), SidebarStrings.costRunning("2h 14m"), SidebarStrings.costSoFar("$0.59")].joined(separator: " · "))
    }

    @Test func aFreshMachineReadsUnderOneCent() throws {
        let cost = try #require(CloudCreationRows.cost(Self.machine(.running, runningFor: 60), limits: nil))
        #expect(cost.usage(now: Self.now, locale: Self.enUS)
            == [SidebarStrings.costRate("$0.26"), SidebarStrings.costRunning("1m"), SidebarStrings.costUnderSoFar("$0.01")].joined(separator: " · "))
    }

    @Test func aMachineWithoutARateShowsOnlyItsTime() throws {
        let cost = try #require(CloudCreationRows.cost(Self.machine(.running, rate: nil), limits: nil))
        #expect(cost.estimatedCostUsd(now: Self.now) == nil)
        #expect(cost.usage(now: Self.now, locale: Self.enUS) == SidebarStrings.costRunning("2h 14m"))
    }

    // MARK: Paused

    /// A paused machine costs no compute: no running time, no estimate, only
    /// its rate "when running", even if a stale start came with the record.
    @Test func aPausedMachineShowsNoRunningCost() throws {
        let cost = try #require(CloudCreationRows.cost(Self.machine(.paused), limits: nil))
        #expect(cost.runningSince == nil)
        #expect(cost.estimatedCostUsd(now: Self.now) == nil)
        #expect(cost.usage(now: Self.now, locale: Self.enUS) == SidebarStrings.costRateWhenRunning("$0.26"))

        let fields = CloudHandlers.costFields(Self.machine(.paused), now: Self.now)
        #expect(fields["hourly_rate_usd"] == .double(0.2645))
        #expect(fields["running_since"] == nil)
        #expect(fields["estimated_cost_usd"] == nil)
    }

    @Test func aMachineWithNoCostFactsHasNoCostLine() {
        #expect(CloudCreationRows.cost(Self.machine(.paused, rate: nil, runningFor: nil), limits: nil) == nil)
    }

    // MARK: Cap

    @Test func theCapFollowsTheServerLimitNullNOrZero() {
        #expect(SidebarMachine.Cost.Cap(maxActiveVms: nil, running: 2) == .uncapped(running: 2))
        #expect(SidebarMachine.Cost.Cap(maxActiveVms: 3, running: 2) == .capped(running: 2, max: 3))
        #expect(SidebarMachine.Cost.Cap(maxActiveVms: 0, running: 0) == .closed)

        #expect(SidebarMachine.Cost.Cap.uncapped(running: 2).text == SidebarStrings.capNone(2))
        #expect(SidebarMachine.Cost.Cap.capped(running: 2, max: 3).text == SidebarStrings.capOf(2, 3))
        #expect(SidebarMachine.Cost.Cap.closed.text == SidebarStrings.capClosed)
    }

    /// The cap comes from `limits`, not from how many machines the list holds.
    @Test func theCapComesFromLimitsNotTheList() throws {
        let capped = try #require(CloudCreationRows.cost(Self.machine(.running), limits: CloudMachineLimits(maxActiveVms: 3, activeVmCount: 2)))
        #expect(capped.cap == .capped(running: 2, max: 3))
        let closed = try #require(CloudCreationRows.cost(Self.machine(.paused, rate: nil, runningFor: nil),
                                                         limits: CloudMachineLimits(maxActiveVms: 0, activeVmCount: 0)))
        #expect(closed.cap == .closed)
        #expect(closed.lines(now: Self.now, locale: Self.enUS) == [SidebarStrings.capClosed])
        #expect(try #require(CloudCreationRows.cost(Self.machine(.running), limits: nil)).cap == nil)
    }

    // MARK: Decoding

    @Test func theMachineListDecodesRateStartAndLimits() throws {
        let body = #"""
        {"vms":[{"id":"vm-1","status":"running","hourlyRateUsd":0.2645,"runningSince":1800000000000},
                {"id":"vm-2","status":"paused","hourlyRateUsd":null,"runningSince":null}],
         "limits":{"maxActiveVms":null,"activeVmCount":1}}
        """#
        let list = try JSONDecoder().decode(CloudMachineList.self, from: Data(body.utf8))
        #expect(list.vms[0].hourlyRateUsd == 0.2645)
        #expect(list.vms[0].runningSince == Self.now)
        #expect(list.vms[1].hourlyRateUsd == nil)
        #expect(list.vms[1].runningSince == nil)
        #expect(list.limits == CloudMachineLimits(maxActiveVms: nil, activeVmCount: 1))

        let capped = try JSONDecoder().decode(CloudMachineList.self, from: Data(#"{"vms":[],"limits":{"maxActiveVms":3,"activeVmCount":2}}"#.utf8))
        #expect(capped.limits == CloudMachineLimits(maxActiveVms: 3, activeVmCount: 2))
        let closed = try JSONDecoder().decode(CloudMachineList.self, from: Data(#"{"vms":[],"limits":{"maxActiveVms":0,"activeVmCount":0}}"#.utf8))
        #expect(closed.limits?.maxActiveVms == 0)
    }

    /// A cost or cap this client cannot read drops the line, never the machines.
    @Test func malformedCostFactsKeepTheMachines() throws {
        let body = #"{"vms":[{"id":"vm-1","status":"running","hourlyRateUsd":"cheap","runningSince":"soon"}],"limits":"open"}"#
        let list = try JSONDecoder().decode(CloudMachineList.self, from: Data(body.utf8))
        #expect(list.vms.map(\.id) == ["vm-1"])
        #expect(list.vms[0].hourlyRateUsd == nil)
        #expect(list.vms[0].runningSince == nil)
        #expect(list.limits == nil)
        #expect(try JSONDecoder().decode(CloudMachineList.self, from: Data(#"{"vms":[]}"#.utf8)).limits == nil)
    }

    // MARK: Surfaces

    /// Hovering a Cloud machine's sidebar header shows its cost under the status.
    @Test func theCloudHeaderTooltipCarriesTheCostLine() throws {
        let cost = SidebarMachine.Cost(hourlyRateUsd: 0.2645, runningSince: Date().addingTimeInterval(-8_040), cap: .capped(running: 2, max: 3))
        let tip = try #require(Self.header(SidebarMachine(id: MachineID("vm-cost"), name: "api", kind: .cloud, status: .connected, cost: cost)).themedToolTip)
        let lines = tip.components(separatedBy: "\n")
        #expect(lines.first == SidebarStrings.statusConnected)
        #expect(lines.last == SidebarStrings.capOf(2, 3))
        #expect(lines.count == 3)

        #expect(SectionHeaderRowView.machineToolTip(status: SidebarStrings.statusConnected, cost: cost, now: Self.now)
            == ([SidebarStrings.statusConnected] + cost.lines(now: Self.now)).joined(separator: "\n"))
        #expect(SectionHeaderRowView.machineToolTip(status: nil, cost: nil, now: Self.now) == nil)
    }

    /// Only Cloud machines bill: another kind's header ignores a cost.
    @Test func anSSHHeaderShowsNoCost() {
        let cost = SidebarMachine.Cost(hourlyRateUsd: 0.2645, runningSince: Self.now, cap: .closed)
        #expect(Self.header(SidebarMachine(id: MachineID("box"), name: "box", kind: .ssh, status: .connected, cost: cost)).themedToolTip
            == SidebarStrings.statusConnected)
    }

    /// `cloud machine-status` answers agents with the cost fields.
    @Test func machineStatusFieldsCarryTheCost() {
        let fields = CloudHandlers.costFields(Self.machine(.running), now: Self.now)
        #expect(fields["hourly_rate_usd"] == .double(0.2645))
        #expect(fields["running_since"] == .string(Self.now.addingTimeInterval(-8_040).ISO8601Format()))
        #expect(fields["estimated_cost_usd"] == .double(0.5907))
    }

    private static func header(_ machine: SidebarMachine) -> SectionHeaderRowView {
        let section = CmuxNextSidebar.SidebarSection(kind: .machine(machine), nodes: [
            .workspace(SidebarWorkspace(id: WorkspaceID("ws-\(machine.id.rawValue)"), title: "api", lastActivity: Date())),
        ])
        let row = SidebarRow(key: .section(section.id), y: 0, height: 28, section: section.id, siblingIndex: 0,
                             isLastInGroup: true, isCollapsed: false, childCount: 1)
        let view = SectionHeaderRowView(key: .section(section.id))
        view.frame = NSRect(x: 0, y: 0, width: 260, height: 28)
        view.configure(section, row: row)
        return view
    }
}
