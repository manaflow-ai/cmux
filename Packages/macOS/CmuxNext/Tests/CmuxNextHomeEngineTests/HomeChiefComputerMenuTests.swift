@testable import CmuxNextHomeEngine
import Testing

/// The card's Computer picker: this Chief's computer and This Mac first, the account's other
/// machines under a heading, tooling's own machines out of the list.
@MainActor @Suite struct HomeChiefComputerMenuTests {
    private typealias Row = HomeChiefComputerMenu.Row
    private let thisMac = Row.computer(title: HomeEngineStrings.computerThisMac, target: nil)
    private let others = Row.heading(HomeEngineStrings.computerOthers)

    private func rows(_ computer: String?, chief: String = "Ada", _ machines: [HomeChiefCloudComputer]) -> [Row] {
        HomeChiefComputerMenu(chief: chief, computer: computer, machines: machines).rows
    }

    private func row(_ title: String, _ id: String) -> Row { .computer(title: title, target: "machine:\(id)") }

    @Test func theChiefsComputerAndThisMacComeFirstAndOthersFollowSorted() {
        let machines = [HomeChiefCloudComputer(id: "z", title: "zeta"), .init(id: "own", title: "Ada’s Computer"), .init(id: "a", title: "alpha")]
        #expect(rows(nil, machines) == [row("Ada’s Computer", "own"), thisMac, .separator, others, row("alpha", "a"), row("zeta", "z"), .separator, .new])
    }

    @Test func aNumberedComputerIsTheChiefsToo() {
        #expect(HomeChiefComputerMenu.isNamed("Ada 2’s Computer", after: "Ada"))
        #expect(!HomeChiefComputerMenu.isNamed("Ada Lab’s Computer", after: "Ada"))
        #expect(!HomeChiefComputerMenu.isNamed("Grace’s Computer", after: "Ada"))
        #expect(!HomeChiefComputerMenu.isNamed("Ada’s Computer", after: ""))
    }

    @Test func leaseAndInfrastructureMachinesStayOutUnlessAttached() {
        let machines = [HomeChiefCloudComputer(id: "l", title: "lease-lease_21_c6c62cab"), .init(id: "f", title: "fs-probe", isInternal: true)]
        #expect(rows(nil, machines) == [thisMac, .separator, .new])
        #expect(rows("machine:l", machines) == [row("lease-lease_21_c6c62cab", "l"), thisMac, .separator, .new])
    }

    @Test func aGenericMachineShowsAsTheChiefsOnlyWhileAttached() {
        let machine = HomeChiefCloudComputer(id: "m", title: "Cloud Machine 5", isGenericName: true)
        #expect(rows("machine:m", [machine]) == [row("Ada’s Computer", "m"), thisMac, .separator, .new])
        #expect(rows(nil, [machine]) == [thisMac, .separator, others, row("Cloud Machine 5", "m"), .separator, .new])
    }

    @Test func aTypedNameStaysWhenAttached() {
        let machine = HomeChiefCloudComputer(id: "m", title: "inference-gateway")
        #expect(rows("machine:m", [machine]) == [row("inference-gateway", "m"), thisMac, .separator, .new])
    }

    @Test func theChiefsOwnComputerTakesItsName() {
        #expect(rows("chief:c1", []) == [.computer(title: "Ada’s Computer", target: "chief:c1"), thisMac, .separator, .new])
        #expect(rows("chief:c1", chief: "", []) == [.computer(title: HomeEngineStrings.computerOwn, target: "chief:c1"), thisMac, .separator, .new])
    }

    @Test func aMachineTheListLostStaysShown() {
        #expect(rows("machine:gone", []) == [.computer(title: "machine:gone", target: "machine:gone"), thisMac, .separator, .new])
    }
}
