import Foundation
import Testing
@testable import CmuxUpdater

@MainActor
@Suite struct UpdateInstallGateTests {
    @Test func driverBlocksInstallWhenTerminalWarningIsDeclined() {
        let summary = UpdateInstallGate.TerminalSessionSummary(
            windowCount: 1,
            workspaceCount: 2,
            terminalCount: 2,
            runningCommandCount: 1
        )
        let delegate = DriverGateDelegate(summary: summary, confirmationResult: false)
        let driver = makeDriver(delegate: delegate)

        #expect(!driver.confirmUpdateInstallAfterTerminalWarningForImmediateInstall())
        #expect(delegate.promptedSummary == summary)
    }

    @Test func driverDoesNotPromptAgainAfterTerminalWarningConfirmed() {
        let terminalPanelId = UUID()
        let summary = UpdateInstallGate.TerminalSessionSummary(
            windowCount: 1,
            workspaceCount: 1,
            terminalCount: 1,
            runningCommandCount: 1,
            terminalPanelIds: [terminalPanelId],
            runningCommandPanelIds: [terminalPanelId]
        )
        let delegate = DriverGateDelegate(summary: summary, confirmationResult: true)
        let driver = makeDriver(delegate: delegate)

        #expect(driver.confirmUpdateInstallAfterTerminalWarningForImmediateInstall())
        #expect(driver.confirmUpdateInstallAfterTerminalWarningForImmediateInstall())
        #expect(delegate.promptCount == 1)
    }

    @Test func driverPromptsAgainWhenNewTerminalAppearsAfterConfirmation() {
        let firstPanelId = UUID()
        let secondPanelId = UUID()
        let delegate = DriverGateDelegate(
            summary: UpdateInstallGate.TerminalSessionSummary(
                windowCount: 1,
                workspaceCount: 1,
                terminalCount: 1,
                runningCommandCount: 0,
                terminalPanelIds: [firstPanelId]
            ),
            confirmationResult: true
        )
        let driver = makeDriver(delegate: delegate)

        #expect(driver.confirmUpdateInstallAfterTerminalWarningForImmediateInstall())

        delegate.summary = UpdateInstallGate.TerminalSessionSummary(
            windowCount: 1,
            workspaceCount: 1,
            terminalCount: 2,
            runningCommandCount: 0,
            terminalPanelIds: [firstPanelId, secondPanelId]
        )

        #expect(driver.confirmUpdateInstallAfterTerminalWarningForImmediateInstall())
        #expect(delegate.promptCount == 2)
    }

    @Test func driverPromptsAgainWhenCommandStartsAfterConfirmation() {
        let terminalPanelId = UUID()
        let delegate = DriverGateDelegate(
            summary: UpdateInstallGate.TerminalSessionSummary(
                windowCount: 1,
                workspaceCount: 1,
                terminalCount: 1,
                runningCommandCount: 0,
                terminalPanelIds: [terminalPanelId]
            ),
            confirmationResult: true
        )
        let driver = makeDriver(delegate: delegate)

        #expect(driver.confirmUpdateInstallAfterTerminalWarningForImmediateInstall())

        delegate.summary = UpdateInstallGate.TerminalSessionSummary(
            windowCount: 1,
            workspaceCount: 1,
            terminalCount: 1,
            runningCommandCount: 1,
            terminalPanelIds: [terminalPanelId],
            runningCommandPanelIds: [terminalPanelId]
        )

        #expect(driver.confirmUpdateInstallAfterTerminalWarningForImmediateInstall())
        #expect(delegate.promptCount == 2)
    }

    private func makeDriver(delegate: DriverGateDelegate) -> UpdateDriver {
        let driver = UpdateDriver(
            model: UpdateStateModel(),
            log: NoopUpdateLog(),
            clock: ImmediateUpdateClock()
        )
        driver.actionDelegate = delegate
        return driver
    }
}

private struct NoopUpdateLog: UpdateLogging {
    func append(_ message: String) {}

    func logPath() -> String {
        ""
    }
}

private struct ImmediateUpdateClock: UpdateClock {
    func sleep(for duration: Duration) async throws {}
}

@MainActor
private final class DriverGateDelegate: UpdateActionDelegate {
    var summary: UpdateInstallGate.TerminalSessionSummary
    let confirmationResult: Bool
    private(set) var promptCount = 0
    private(set) var promptedSummary: UpdateInstallGate.TerminalSessionSummary?

    init(
        summary: UpdateInstallGate.TerminalSessionSummary,
        confirmationResult: Bool
    ) {
        self.summary = summary
        self.confirmationResult = confirmationResult
    }

    func updaterRequestsRetryCheckForUpdates() {}

    func updaterTerminalSessionSummaryForUpdateInstall() -> UpdateInstallGate.TerminalSessionSummary {
        summary
    }

    func updaterConfirmTerminalTerminationForUpdateInstall(
        summary: UpdateInstallGate.TerminalSessionSummary
    ) -> Bool {
        promptCount += 1
        promptedSummary = summary
        return confirmationResult
    }

    func updaterWillRelaunchApplication() {}
}
