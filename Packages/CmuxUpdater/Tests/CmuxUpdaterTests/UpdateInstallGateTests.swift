import Foundation
@preconcurrency import Sparkle
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

    @Test func driverDefersReadyInstallWithoutDismissingSparkleWhenTerminalWarningDeclined() {
        let summary = UpdateInstallGate.TerminalSessionSummary(
            windowCount: 1,
            workspaceCount: 1,
            terminalCount: 1,
            runningCommandCount: 1
        )
        let delegate = DriverGateDelegate(summary: summary, confirmationResult: false)
        let driver = makeDriver(delegate: delegate)
        let recorder = UpdateChoiceRecorder()
        var deferredCount = 0
        driver.installDeferred = {
            deferredCount += 1
        }

        driver.showReady(toInstallAndRelaunch: { recorder.record($0) })

        #expect(recorder.snapshot().isEmpty)
        #expect(deferredCount == 1)
        if case .installing = driver.model.state {
            #expect(true)
        } else {
            #expect(Bool(false), "declining the terminal warning should leave a retryable install state")
        }
    }

    @Test func driverRetriesDeferredReadyInstallAfterTerminalWarningConfirmed() {
        let summary = UpdateInstallGate.TerminalSessionSummary(
            windowCount: 1,
            workspaceCount: 1,
            terminalCount: 1,
            runningCommandCount: 1
        )
        let delegate = DriverGateDelegate(summary: summary, confirmationResult: false)
        let driver = makeDriver(delegate: delegate)
        let recorder = UpdateChoiceRecorder()

        driver.showReady(toInstallAndRelaunch: { recorder.record($0) })
        delegate.confirmationResult = true

        guard case .installing(let installing) = driver.model.state else {
            #expect(Bool(false), "declined ready install should become retryable")
            return
        }
        installing.retryTerminatingApplication()

        #expect(recorder.snapshot() == [.install])
        #expect(delegate.promptCount == 2)
    }

    @Test func driverDismissesDeferredReadyInstallByReplyingDismissToSparkle() {
        let summary = UpdateInstallGate.TerminalSessionSummary(
            windowCount: 1,
            workspaceCount: 1,
            terminalCount: 1,
            runningCommandCount: 1
        )
        let delegate = DriverGateDelegate(summary: summary, confirmationResult: false)
        let driver = makeDriver(delegate: delegate)
        let recorder = UpdateChoiceRecorder()

        driver.showReady(toInstallAndRelaunch: { recorder.record($0) })

        guard case .installing(let installing) = driver.model.state else {
            #expect(Bool(false), "declined ready install should become retryable")
            return
        }
        installing.dismiss()

        #expect(recorder.snapshot() == [.dismiss])
        #expect(driver.model.state == .idle)
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

private final class UpdateChoiceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var choices: [SPUUserUpdateChoice] = []

    func record(_ choice: SPUUserUpdateChoice) {
        lock.withLock {
            choices.append(choice)
        }
    }

    func snapshot() -> [SPUUserUpdateChoice] {
        lock.withLock {
            choices
        }
    }
}

@MainActor
private final class DriverGateDelegate: UpdateActionDelegate {
    var summary: UpdateInstallGate.TerminalSessionSummary
    var confirmationResult: Bool
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
