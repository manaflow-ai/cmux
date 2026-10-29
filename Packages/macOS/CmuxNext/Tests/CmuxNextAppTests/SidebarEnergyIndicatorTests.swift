import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextWakeups
import Testing

/// Energy Saver's leaf in the sidebar footer: it follows only the app's one
/// ``EnergyPolicySource`` (`MainWorkScheduler.energy`), shows while the saver is on with the saver's
/// reason in its card, and its card's "Turn Off for Now" reaches the App.
@MainActor
struct SidebarEnergyIndicatorTests {
    private static func sidebar(batteryPercent: @escaping () -> Int? = { nil }) -> (SidebarContainerView, MainWorkScheduler) {
        let mainWork = MainWorkScheduler(budget: MainFrameBudget())
        let container = SidebarContainerView(model: SidebarModel(), mainWork: mainWork)
        container.sidebarView.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        container.sidebarView.followEnergy(MainDeadlineScheduler(work: mainWork), batteryPercent: batteryPercent)
        return (container, mainWork)
    }

    /// `view` in a window that is never ordered in: it has no screen, so its Motion changes apply at
    /// once wherever AppKit reports none (`Motion.canAnimate`).
    private static func offscreen(_ view: NSView) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = view
        return window
    }

    /// Waits until `done` holds, at most five seconds: a fade's completion comes from AppKit.
    private static func settle(_ message: Comment, until done: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !done(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10)) // test-only: the fade's completion is AppKit's, bounded
        }
        try #require(done(), message)
    }

    /// Whatever the motion settings: the leaf shows in the policy's turn and hides once its fade ends.
    @Test func leafShowsOnlyWhileTheSaverIsOn() async throws {
        let (container, mainWork) = Self.sidebar()
        let window = Self.offscreen(container)
        defer { window.close() }
        let leaf = container.sidebarView.energyIndicator
        #expect(!leaf.isShown)
        #expect(leaf.isHidden)

        mainWork.energy.update(EnergyPolicy(saverReason: .lowPowerMode))
        #expect(leaf.isShown)
        #expect(!leaf.isHidden)
        #expect(leaf.reason == .lowPowerMode)

        mainWork.energy.update(.normal)
        #expect(!leaf.isShown)
        #expect(leaf.reason == nil)
        #expect(leaf.button.alphaValue == 0)
        try await Self.settle("the leaf never hid after the saver went off") { leaf.isHidden }
    }

    /// With the fade running, the leaf hides only when it ends, and a saver back on during the fade
    /// keeps it (the old fade's completion must not hide it).
    @Test(.enabled("needs a display that draws frames, or every change applies at once") {
        await GUIAnimationTestSupport.animatesHere()
    })
    func aFadeOutHidesTheLeafOnlyAtItsEnd() async throws {
        let duration = Motion.indicators.duration(.fadeOut)
        guard duration > 0 else { return }
        let (container, mainWork) = Self.sidebar()
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 260, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        window.orderFrontRegardless()
        defer { window.close() }
        try #require(window.screen != nil, "the window is on no screen: nothing animates")
        let leaf = container.sidebarView.energyIndicator

        mainWork.energy.update(EnergyPolicy(saverReason: .lowPowerMode))
        mainWork.energy.update(.normal)
        #expect(!leaf.isShown)
        #expect(leaf.button.alphaValue == 0, "the fade's target is not transparent")
        #expect(!leaf.isHidden, "the leaf hid before its fade ended")

        mainWork.energy.update(EnergyPolicy(saverReason: .lowPowerMode))
        try await Task.sleep(for: .seconds(duration) + .milliseconds(300)) // test-only: past the old fade's end
        #expect(!leaf.isHidden, "the old fade's completion hid the leaf shown again")
        #expect(leaf.button.alphaValue == 1)

        mainWork.energy.update(.normal)
        try await Self.settle("the leaf never hid after its fade") { leaf.isHidden }
    }

    @Test func aSaverOnAtFollowShowsAtOnce() {
        let mainWork = MainWorkScheduler(budget: MainFrameBudget())
        mainWork.energy.update(EnergyPolicy(saverReason: .battery))
        let container = SidebarContainerView(model: SidebarModel(), mainWork: mainWork)
        container.sidebarView.followEnergy(MainDeadlineScheduler(work: mainWork))
        let leaf = container.sidebarView.energyIndicator
        #expect(leaf.isShown)
        #expect(!leaf.isHidden)
        #expect(leaf.button.alphaValue == 1)
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

    /// p14-energy.md D: the card names the battery's charge ("battery at N%").
    @Test func aLowBatteryCardNamesTheCharge() {
        var percent = 15
        let (container, mainWork) = Self.sidebar(batteryPercent: { percent })
        let leaf = container.sidebarView.energyIndicator
        mainWork.energy.update(EnergyPolicy(saverReason: .battery, onBattery: true))
        #expect(leaf.card.reportedLines[1] == Strings.energySaverReason(.battery, batteryPercent: 15))
        #expect(leaf.card.reportedLines[1].contains("15"))
        #expect(leaf.card.reportedLines[1] != Strings.energySaverReason(.battery))

        // A later read takes the charge then (the card reads it when its content changes or it opens).
        percent = 9
        mainWork.energy.update(EnergyPolicy(saverReason: .battery))
        #expect(leaf.card.reportedLines[1].contains("9"))
        // Another reason names no charge.
        mainWork.energy.update(EnergyPolicy(saverReason: .lowPowerMode, onBattery: true))
        #expect(!leaf.card.reportedLines[1].contains("9"))
    }

    /// "Turn Off for Now" holds until the battery -> AC edge or a setting change
    /// (`EnergyPolicyResolver.update`): plugged in, its help must not promise the plug.
    @Test func turnOffHelpSaysWhatEndsTheHold() {
        let (container, mainWork) = Self.sidebar()
        let turnOff = container.sidebarView.energyIndicator.card.turnOff
        mainWork.energy.update(EnergyPolicy(saverReason: .lowPowerMode))
        #expect(turnOff.themedToolTip == Strings.energySaverTurnOffForNowHelp(onBattery: false))
        #expect(turnOff.accessibilityLabel() == Strings.energySaverTurnOffForNowHelp(onBattery: false))
        mainWork.energy.update(EnergyPolicy(saverReason: .lowPowerMode, onBattery: true))
        #expect(turnOff.themedToolTip == Strings.energySaverTurnOffForNowHelp(onBattery: true))
        #expect(Strings.energySaverTurnOffForNowHelp(onBattery: false) != Strings.energySaverTurnOffForNowHelp(onBattery: true))
    }

    /// Full Keyboard Access reaches the leaf (Tab, Space), as it does a card's x.
    @Test func leafTakesKeyFocus() {
        let leaf = SidebarEnergyIndicator()
        #expect(leaf.button.takesKeyFocus)
        #expect(!leaf.button.refusesFirstResponder)
    }

    /// The pointer opens the card while a Chromium page's window or a panel holds the key, as the
    /// Updated card's x does (SidebarUpdatedCardHost).
    @Test func leafTracksThePointerInTheActiveApp() {
        let leaf = SidebarEnergyIndicator(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        leaf.updateTrackingAreas()
        let options = leaf.trackingAreas.map(\.options)
        #expect(options.contains { $0.contains(.activeInActiveApp) && $0.contains(.mouseEnteredAndExited) })
        #expect(!options.contains { $0.contains(.activeInKeyWindow) })
    }

    /// Minimal mode hiding the bottom bands fades the leaf with the footer and the Search button; the
    /// saver's own show/hide stays on the leaf's button, so neither fade undoes the other.
    @Test func minimalModeFadesTheLeafWithTheFooter() {
        let design = DesignSettings()
        design.sidebarSections.minimalMode = .bottom
        let sidebar = SidebarView(model: SidebarModel(), design: design)
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        let window = Self.offscreen(sidebar)
        defer { window.close() }
        let leaf = sidebar.energyIndicator
        leaf.apply(EnergyPolicy(saverReason: .lowPowerMode), animated: false)

        sidebar.setChromeRevealed(false)
        #expect(sidebar.searchButton.alphaValue == 0)
        #expect(leaf.alphaValue == 0, "the leaf stayed opaque where the footer faded")
        #expect(leaf.button.alphaValue == 1, "the reveal wrote the saver's fade")
        #expect(!leaf.isHidden)

        sidebar.setChromeRevealed(true)
        #expect(leaf.alphaValue == 1)
        #expect(leaf.button.alphaValue == 1)
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
