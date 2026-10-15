import CmuxBrowser
import Darwin
import Foundation
import Testing

@Suite struct BrowserPageProcessExitChromiumTests {
    @Test(arguments: [
        (0, BrowserPageProcessExit.Kind.other),
        (1, .killed),
        (2, .crashed),
        (3, .outOfMemory),
        (4, .launchFailed),
        (5, .other),
        (99, .other),
    ])
    func mapsCEFTerminationStatus(status: Int, kind: BrowserPageProcessExit.Kind) {
        #expect(BrowserPageProcessExit.chromium(terminationStatus: status, code: 11).kind == kind)
    }

    @Test func zeroCodeIsUnknown() {
        #expect(BrowserPageProcessExit.chromium(terminationStatus: 2, code: 0).status == nil)
        #expect(BrowserPageProcessExit.chromium(terminationStatus: 2, code: 0).codeDescription == nil)
    }

    @Test func describesSignalsAndExitStatuses() {
        #expect(BrowserPageProcessExit(kind: .crashed, status: SIGSEGV).codeDescription == "SIGSEGV")
        #expect(BrowserPageProcessExit(kind: .killed, status: SIGKILL).codeDescription == "SIGKILL")
        #expect(BrowserPageProcessExit(kind: .crashed, status: 0x80 | SIGTRAP).codeDescription == "SIGTRAP")
        #expect(BrowserPageProcessExit(kind: .crashed, status: 31).codeDescription == "signal 31")
        #expect(BrowserPageProcessExit(kind: .other, status: 3 << 8).codeDescription == "exit 3")
    }

    @Test func helperWaitStatusClassification() {
        // Normal ends: exit 0, SIGTERM (Chromium retiring a helper), a stop.
        #expect(BrowserPageProcessExit.helperExitKind(waitStatus: 0) == nil)
        #expect(BrowserPageProcessExit.helperExitKind(waitStatus: SIGTERM) == nil)
        #expect(BrowserPageProcessExit.helperExitKind(waitStatus: 0x7f | (SIGSTOP << 8)) == nil)
        // Abnormal ends.
        #expect(BrowserPageProcessExit.helperExitKind(waitStatus: SIGKILL) == .killed)
        #expect(BrowserPageProcessExit.helperExitKind(waitStatus: SIGSEGV) == .crashed)
        #expect(BrowserPageProcessExit.helperExitKind(waitStatus: SIGABRT | 0x80) == .crashed)
        #expect(BrowserPageProcessExit.helperExitKind(waitStatus: 1 << 8) == .other)
    }
}

@Suite struct BrowserCrashReloadGuardTests {
    @Test func visiblePaneNeverRestoresByItself() {
        var guardState = BrowserCrashReloadGuard()
        let now = Date(timeIntervalSince1970: 1_000)
        let result1 = guardState.allowsAutomaticRestore(at: now, paneWasVisible: true)
        #expect(!result1)
        // A visible crash does not spend the hidden budget.
        for index in 0..<BrowserCrashReloadGuard.limit {
            let result2 = guardState.allowsAutomaticRestore(at: now.addingTimeInterval(Double(index)), paneWasVisible: false)
            #expect(result2)
        }
    }

    @Test func stopsHiddenRestoresAfterLimitWithinWindow() {
        var guardState = BrowserCrashReloadGuard()
        let start = Date(timeIntervalSince1970: 1_000)
        for index in 0..<BrowserCrashReloadGuard.limit {
            let result3 = guardState.allowsAutomaticRestore(at: start.addingTimeInterval(Double(index)), paneWasVisible: false)
            #expect(result3)
        }
        let result4 = guardState.allowsAutomaticRestore(at: start.addingTimeInterval(10), paneWasVisible: false)
        #expect(!result4)
    }

    @Test func oldRestoresLeaveTheWindow() {
        var guardState = BrowserCrashReloadGuard()
        let start = Date(timeIntervalSince1970: 1_000)
        for index in 0..<BrowserCrashReloadGuard.limit {
            _ = guardState.allowsAutomaticRestore(at: start.addingTimeInterval(Double(index)), paneWasVisible: false)
        }
        let later = start.addingTimeInterval(BrowserCrashReloadGuard.window + 5)
        let result5 = guardState.allowsAutomaticRestore(at: later, paneWasVisible: false)
        #expect(result5)
    }

    @Test func explicitReloadResetsTheBudget() {
        var guardState = BrowserCrashReloadGuard()
        let now = Date(timeIntervalSince1970: 1_000)
        for _ in 0...BrowserCrashReloadGuard.limit { _ = guardState.allowsAutomaticRestore(at: now, paneWasVisible: false) }
        guardState.reset()
        let result6 = guardState.allowsAutomaticRestore(at: now, paneWasVisible: false)
        #expect(result6)
    }
}

@Suite @MainActor struct BrowserCrashLogTests {
    @Test func keepsANewestBoundedRingAndNotifiesObservers() {
        let log = BrowserCrashLog()
        var seen = 0
        let token = log.addObserver { _ in seen += 1 }
        for index in 0..<(BrowserCrashLog.capacity + 5) {
            log.append(BrowserCrashRecord(processType: "renderer", pid: Int32(index), kind: .crashed, source: .process))
        }
        #expect(log.records.count == BrowserCrashLog.capacity)
        #expect(log.records.last?.pid == Int32(BrowserCrashLog.capacity + 4))
        #expect(log.total == BrowserCrashLog.capacity + 5)
        #expect(seen == BrowserCrashLog.capacity + 5)
        log.removeObserver(token)
        log.append(BrowserCrashRecord(processType: "gpu-process", kind: .killed, status: SIGKILL, source: .process))
        #expect(seen == BrowserCrashLog.capacity + 5)
        #expect(log.records.last?.codeDescription == "SIGKILL")
    }
}
