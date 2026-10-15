@testable import CmuxBrowser
import Darwin
import Foundation
import Testing

@Suite struct ChromiumHelperIdentityTests {
    @Test func parsesHelperSwitches() {
        let renderer = ChromiumHelperIdentity.parse(["/x/cmux Helper (Renderer)", "--type=renderer", "--renderer-client-id=7"])
        #expect(renderer == ChromiumHelperIdentity(processType: "renderer"))
        #expect(renderer?.recordedType == "renderer")

        let network = ChromiumHelperIdentity.parse(["h", "--type=utility", "--utility-sub-type=network.mojom.NetworkService"])
        #expect(network?.subType == "network.mojom.NetworkService")

        let extensionRenderer = ChromiumHelperIdentity.parse(["h", "--type=renderer", "--extension-process"])
        #expect(extensionRenderer?.recordedType == "extension")
    }

    @Test func nonHelpersHaveNoIdentity() {
        #expect(ChromiumHelperIdentity.parse(["/bin/zsh", "-l"]) == nil)
        #expect(ChromiumHelperIdentity.parse(["h", "--type="]) == nil)
        #expect(ChromiumHelperIdentity.parse([]) == nil)
    }

    @Test func parsesKernProcArgs2Layout() {
        var buffer: [UInt8] = []
        withUnsafeBytes(of: Int32(2)) { buffer.append(contentsOf: $0) }
        buffer.append(contentsOf: Array("/exec/path".utf8) + [0, 0, 0])
        buffer.append(contentsOf: Array("helper".utf8) + [0])
        buffer.append(contentsOf: Array("--type=gpu-process".utf8) + [0])
        buffer.append(contentsOf: Array("ENV=1".utf8) + [0])
        #expect(ChromiumHelperIdentity.parseProcArgs(buffer) == ["helper", "--type=gpu-process"])
    }

    @Test func readsOwnProcessArguments() {
        // This test process is not a Chromium helper, but its argv is readable.
        #expect(!ChromiumHelperIdentity.arguments(pid: getpid()).isEmpty)
        #expect(ChromiumHelperIdentity.read(pid: getpid()) == nil)
    }
}

@Suite struct ChromiumChildProcessMonitorTests {
    /// A child started with `--type=renderer` in its argv and killed with
    /// SIGKILL is reported as a killed renderer; one that exits 0 is not
    /// reported as abnormal.
    @Test func reportsHelperExitWithWaitStatus() async throws {
        let exits = AsyncStream<ChromiumChildProcessMonitor.Exit>.makeStream()
        let watched = AsyncStream<Int32>.makeStream()
        let monitor = ChromiumChildProcessMonitor(
            onExit: { exits.continuation.yield($0) },
            onWatch: { watched.continuation.yield($0) }
        )
        monitor.start()

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The trailing argument is `$0` for sh; the monitor reads it from argv.
        child.arguments = ["-c", "read line", "--type=renderer"]
        let input = Pipe()
        child.standardInput = input
        try child.run()
        let pid = child.processIdentifier

        // Kill only once the monitor watches this child.
        for await registered in watched.stream where registered == pid { break }
        kill(pid, SIGKILL)

        var reported: ChromiumChildProcessMonitor.Exit?
        for await exit in exits.stream where exit.pid == pid {
            reported = exit
            break
        }
        #expect(reported?.identity.processType == "renderer")
        #expect(reported?.abnormalKind == .killed)
        child.waitUntilExit()
        withExtendedLifetime((monitor, input)) {}
    }
}

@Suite struct ChromiumShutdownSequenceTests {
    @Test func waitsForBrowsersThenWindows() {
        var sequence = ChromiumShutdownSequence(liveBrowsers: 2, windows: 2)
        #expect(sequence.phase == .running)
        sequence.begin()
        #expect(sequence.phase == .closingBrowsers)
        sequence.windowDestroyed(remaining: 0)
        #expect(sequence.phase == .closingBrowsers)
        sequence.browserClosed(remaining: 1)
        #expect(sequence.phase == .closingBrowsers)
        sequence.browserClosed(remaining: 0)
        #expect(sequence.phase == .readyToShutdown)
    }

    @Test func waitsForForkWindowsAfterBrowsers() {
        var sequence = ChromiumShutdownSequence(liveBrowsers: 1, windows: 1)
        sequence.begin()
        sequence.browserClosed(remaining: 0)
        #expect(sequence.phase == .waitingForWindows)
        sequence.windowDestroyed(remaining: 0)
        #expect(sequence.phase == .readyToShutdown)
    }

    @Test func stockCEFWithoutWindowCountSkipsThatWait() {
        var sequence = ChromiumShutdownSequence(liveBrowsers: 0, windows: -1)
        sequence.begin()
        #expect(sequence.phase == .readyToShutdown)
    }

    @Test func beginIsIdempotent() {
        var sequence = ChromiumShutdownSequence(liveBrowsers: 1, windows: 0)
        sequence.begin()
        sequence.begin()
        #expect(sequence.phase == .closingBrowsers)
    }
}
