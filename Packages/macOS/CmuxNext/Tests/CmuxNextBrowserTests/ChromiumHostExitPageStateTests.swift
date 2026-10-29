#if DEBUG
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.
@testable import CmuxNextBrowser
import Darwin
import Foundation
import Testing

/// A Chromium host's end maps to the crash state its pages show, as Chrome's
/// `GetTerminationStatus` (base/process/kill_posix.cc) maps a child's: a clean exit shows nothing,
/// and a `kill -9` of a real host process is reported as killed while this process runs on.
@Suite struct ChromiumHostExitPageStateTests {
    @Test(arguments: [SIGSEGV, SIGTRAP, SIGABRT, SIGBUS, SIGILL, SIGFPE, SIGSYS])
    func aFaultOrACheckIsACrash(signal: Int32) {
        #expect(ChromiumHostExit(signal: signal, status: nil).pageExit == BrowserProcessExit(reason: .crashed, code: Int(signal), engine: .cef, process: .chromiumHost))
    }

    @Test(arguments: [SIGKILL, SIGINT, SIGTERM])
    func anOutsideEndIsAKill(signal: Int32) {
        #expect(ChromiumHostExit(signal: signal, status: nil).pageExit == BrowserProcessExit(reason: .killed, code: Int(signal), engine: .cef, process: .chromiumHost))
    }

    @Test func anotherSignalIsAbnormal() {
        #expect(ChromiumHostExit(signal: SIGUSR1, status: nil).pageExit?.reason == .abnormal)
    }

    @Test func aCleanExitShowsNothing() {
        #expect(ChromiumHostExit(signal: nil, status: 0).pageExit == nil)
    }

    @Test func aStartFailureIsALaunchFailure() throws {
        let exit = try #require(ChromiumHostExit(signal: nil, status: 67).pageExit)
        #expect(exit.reason == .launchFailed)
        #expect(exit.codeDescription == "exit 67")
    }

    @Test func anyOtherExitIsAbnormal() throws {
        let exit = try #require(ChromiumHostExit(signal: nil, status: 3).pageExit)
        #expect(exit.reason == .abnormal)
        #expect(exit.codeDescription == "exit 3")
    }

    @Test func anUnreadableEndIsStillACrashState() {
        #expect(ChromiumHostExit(signal: nil, status: nil).pageExit?.reason == .abnormal)
    }

    /// A stand-in host killed with SIGKILL right after it starts: its end shows "killed", and the
    /// write to its wire fails without a SIGPIPE, so this process is still here to read it.
    @Test func aKilledHostShowsKilledAndThisProcessRunsOn() async throws {
        let launcher = ChromiumHostLauncher()
        let handle = try await launcher.launch(executable: URL(filePath: "/bin/sh"), arguments: ["-c", "exec /bin/cat <&3 >&4"])
        #expect(kill(handle.pid, SIGKILL) == 0)
        let ended = await launcher.exit(of: handle.pid)
        launcher.reap(handle.pid)
        #expect(ended.pageExit?.reason == .killed)
        #expect(ended.pageExit?.codeDescription == "SIGKILL")
        var byte: UInt8 = 0
        let wrote = Darwin.write(handle.writeFD, &byte, 1)
        let error = errno
        #expect(wrote == -1)
        #expect(error == EPIPE)
        Darwin.close(handle.readFD)
        Darwin.close(handle.writeFD)
    }
}
#endif
