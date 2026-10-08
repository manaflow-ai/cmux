@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextTerminal
import Testing

/// A terminal whose host was killed (tab `end.kind == host_lost`, e.g.
/// `dead_before_adoption` after its host process ended) did not exit
/// normally, so its banner says "Terminal lost: <reason>", not "Process
/// exited" (durable-sessions.md section 7; coordinator decision 2026-10-04).
@MainActor struct TerminalHostLossBannerTests {
    private let missing = ModuleResourceBundle(name: "CmuxNext_Missing", searchDirectories: [])

    @Test func aHostLostEndNamesItsReasonAndAProcessEndDoesNot() {
        func loss(_ reason: TerminalTabEnd.HostLostReason) -> TerminalHostLoss? {
            TerminalLinkWatch.hostLoss(TerminalTabEnd(kind: .hostLost, reason: reason))
        }
        #expect(loss(.deadBeforeAdoption) == .hostEnded)
        #expect(loss(.diedDuringAdoption) == .hostEnded)
        #expect(loss(.diedWithoutExitStatus) == .hostEnded)
        #expect(loss(.missingExitReceipt) == .hostEnded)
        #expect(loss(.unadoptableHostEnded) == .hostEnded)
        #expect(loss(.other) == .hostEnded)
        #expect(loss(.sessionShutdown) == .sessionShutdown)
        #expect(loss(.missingRecord) == .hostMissing)
        #expect(loss(.incarnationMismatch) == .hostMissing)
        #expect(TerminalLinkWatch.hostLoss(TerminalTabEnd(kind: .hostLost)) == .hostEnded, "no reason: the host ended")
        #expect(TerminalLinkWatch.hostLoss(TerminalTabEnd(kind: .exited, code: 0)) == nil)
        #expect(TerminalLinkWatch.hostLoss(TerminalTabEnd(kind: .signaled, signal: 9)) == nil)
        #expect(TerminalLinkWatch.hostLoss(TerminalTabEnd(kind: .launchFailed)) == nil)
        #expect(TerminalLinkWatch.hostLoss(nil) == nil)
    }

    @Test func theBannerSaysTerminalLostForALostHost() {
        #expect(TerminalStatusBanner.text(for: .exited, hostLoss: .hostEnded, strings: missing)
                == "Terminal lost: its host process ended")
        #expect(TerminalStatusBanner.text(for: .exited, hostLoss: .sessionShutdown, strings: missing)
                == "Terminal lost: the session shut down")
        #expect(TerminalStatusBanner.text(for: .exited, hostLoss: .hostMissing, strings: missing)
                == "Terminal lost: its host is gone")
        #expect(TerminalStatusBanner.text(for: .exited, strings: missing) == "Process exited")
        // A reason left over from a dead report never shows on a live view.
        #expect(TerminalStatusBanner.text(for: .connected, hostLoss: .hostEnded, strings: missing) == nil)
    }

    /// cx-0tgl LA: the banner names who ended the host, so an external
    /// killer is visible at once; a process end shows no cause.
    @Test func theBannerNamesTheRecordedCause() {
        let cause = TerminalHostLossCause(signal: "SIGTERM", senderPid: 9, senderName: "bash")
        #expect(TerminalStatusBanner.text(for: .exited, hostLoss: .hostEnded, cause: cause, strings: missing)
                == "Terminal lost: its host process ended · SIGTERM from bash (pid 9)")
        let gone = TerminalHostLossCause(signal: "SIGTERM", senderPid: 9, panicked: true)
        #expect(TerminalStatusBanner.text(for: .exited, hostLoss: .hostEnded, cause: gone, strings: missing)
                == "Terminal lost: its host process ended · SIGTERM from pid 9 · the host had panicked")
        #expect(TerminalStatusBanner.text(for: .exited, hostLoss: .hostEnded, cause: TerminalHostLossCause(),
                                          strings: missing) == "Terminal lost: its host process ended")
        #expect(TerminalStatusBanner.text(for: .exited, cause: cause, strings: missing) == "Process exited")
        #expect(TerminalStatusBanner.text(for: .connected, hostLoss: .hostEnded, cause: cause, strings: missing) == nil)
        let japanese = ModuleResourceBundle.terminal.localization("ja")
        #expect(TerminalStatusBanner.text(for: .exited, hostLoss: .hostEnded, cause: cause, strings: japanese)
                == "ターミナルが失われました: ホストプロセスが終了しました · bash（pid 9）からの SIGTERM")
    }

    @Test func theJapaneseTableIsRead() {
        let japanese = ModuleResourceBundle.terminal.localization("ja")
        #expect(TerminalStatusBanner.text(for: .exited, hostLoss: .hostEnded, strings: japanese)
                == "ターミナルが失われました: ホストプロセスが終了しました")
    }
}
