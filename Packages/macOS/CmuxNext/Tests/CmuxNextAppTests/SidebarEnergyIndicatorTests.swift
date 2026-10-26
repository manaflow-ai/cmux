import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextWakeups
import Testing

/// Energy Saver's leaf in the sidebar footer (p14-energy-026): it follows only the app's one
/// ``EnergyPolicySource`` (`MainWorkScheduler.energy`), shows while the saver is on with the saver's
/// reason in its card, and its card's "Turn Off for Now" reaches the App.
@MainActor
struct SidebarEnergyIndicatorTests {
    private static func sidebar() -> (SidebarContainerView, MainWorkScheduler) {
        let mainWork = MainWorkScheduler(budget: MainFrameBudget())
        let container = SidebarContainerView(model: SidebarModel(), mainWork: mainWork)
        container.sidebarView.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        container.sidebarView.followEnergy(MainDeadlineScheduler(work: mainWork))
        return (container, mainWork)
    }

    @Test func leafShowsOnlyWhileTheSaverIsOn() {
        let (container, mainWork) = Self.sidebar()
        let leaf = container.sidebarView.energyIndicator
        #expect(!leaf.isShown)
        #expect(leaf.isHidden)

        mainWork.energy.update(EnergyPolicy(saverReason: .lowPowerMode))
        #expect(leaf.isShown)
        #expect(!leaf.isHidden)
        #expect(leaf.reason == .lowPowerMode)

        mainWork.energy.update(.normal)
        #expect(!leaf.isShown)
        #expect(leaf.isHidden)
        #expect(leaf.reason == nil)
    }

    @Test func aSaverOnAtFollowShowsAtOnce() {
        let mainWork = MainWorkScheduler(budget: MainFrameBudget())
        mainWork.energy.update(EnergyPolicy(saverReason: .battery))
        let container = SidebarContainerView(model: SidebarModel(), mainWork: mainWork)
        container.sidebarView.followEnergy(MainDeadlineScheduler(work: mainWork))
        let leaf = container.sidebarView.energyIndicator
        #expect(leaf.isShown)
        #expect(leaf.alphaValue == 1)
    }

    @Test func otherPolicyChangesLeaveTheLeafAlone() {
        let (container, mainWork) = Self.sidebar()
        let leaf = container.sidebarView.energyIndicator
        var changes = 0
        leaf.onShownChange = { changes += 1 }
        mainWork.energy.update(EnergyPolicy(saverReason: .setting))
        mainWork.energy.update(EnergyPolicy(saverReason: .setting, onBattery: true))
        mainWork.energy.update(EnergyPolicy(saverReason: .setting, suspended: true, onBattery: true))
        #expect(changes == 1)
        mainWork.energy.update(EnergyPolicy(onBattery: true))
        #expect(changes == 2)
    }

    @Test func cardSaysWhyForEveryReason() {
        let (container, mainWork) = Self.sidebar()
        let leaf = container.sidebarView.energyIndicator
        var reasons = Set<String>()
        for reason in EnergyPolicy.Reason.allCases {
            mainWork.energy.update(EnergyPolicy(saverReason: reason))
            #expect(leaf.reason == reason)
            let lines = leaf.card.reportedLines
            #expect(lines.count == 4)
            #expect(lines.allSatisfy { !$0.isEmpty })
            #expect(lines[1] == Strings.energySaverReason(reason))
            #expect(lines[3] == Strings.energySaverTurnOffForNow)
            reasons.insert(lines[1])
        }
        #expect(reasons.count == EnergyPolicy.Reason.allCases.count)
    }

    @Test func turnOffForNowReachesTheApp() {
        let (container, mainWork) = Self.sidebar()
        var turnedOff = 0
        container.sidebarView.onTurnOffEnergySaver = { turnedOff += 1 }
        mainWork.energy.update(EnergyPolicy(saverReason: .lowPowerMode))
        container.sidebarView.energyIndicator.card.turnOff.press()
        #expect(turnedOff == 1)
    }

    @Test func observesOnlyTheSourceAndLetsGoOfIt() {
        let mainWork = MainWorkScheduler(budget: MainFrameBudget())
        let before = mainWork.energy.observerCount
        weak var released: SidebarEnergyIndicator?
        autoreleasepool {
            let leaf = SidebarEnergyIndicator()
            leaf.follow(MainDeadlineScheduler(work: mainWork))
            #expect(mainWork.energy.observerCount == before + 1)
            released = leaf
        }
        #expect(released == nil)
        #expect(mainWork.energy.observerCount == before)
    }

    @Test func footerMakesRoomForTheLeafAtItsTrailingEnd() {
        let (container, mainWork) = Self.sidebar()
        let sidebar = container.sidebarView
        #expect(sidebar.footerBand.energyRoom == 0)

        mainWork.energy.update(EnergyPolicy(saverReason: .thermal))
        #expect(sidebar.footerBand.energyRoom > 0)
        sidebar.footerBand.placeEnergy()
        let leaf = sidebar.energyIndicator.frame
        #expect(leaf.width == SidebarFooterBand.searchButtonSide)
        #expect(leaf.maxX <= sidebar.bounds.width)
        #expect(leaf.maxX > sidebar.bounds.width - SidebarFooterBand.searchButtonSide - Metrics.space4)
    }
}
