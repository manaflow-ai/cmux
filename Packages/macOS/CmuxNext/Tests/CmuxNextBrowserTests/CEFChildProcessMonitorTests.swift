@testable import CmuxNextBrowser
import Foundation
import Testing

/// The helper monitor's kqueue state lives behind one `Mutex` on its own queue:
/// a child it watches reports its end with its helper identity and wait status. Run under TSan too.
@Suite struct CEFChildProcessMonitorTests {
    @Test(.timeLimit(.minutes(1)))
    func aHelperThatEndsIsReportedWithItsIdentityAndStatus() async throws {
        let (watched, watch) = AsyncStream.makeStream(of: Int32.self)
        let (exits, exit) = AsyncStream.makeStream(of: CEFChildProcessMonitor.Exit.self)
        let monitor = CEFChildProcessMonitor(onExit: { exit.yield($0) }, onWatch: { watch.yield($0) })
        monitor.start()
        monitor.start()

        let input = Pipe()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        // A stand-in helper: Chromium's switches in its argv, alive until its stdin closes.
        child.arguments = ["-c", "read line; exit 3", "sh", "--type=utility", "--utility-sub-type=network.mojom.NetworkService"]
        child.standardInput = input
        try child.run()
        let pid = child.processIdentifier

        for await watchedPID in watched where watchedPID == pid { break }
        try input.fileHandleForWriting.close()
        var ended: CEFChildProcessMonitor.Exit?
        for await candidate in exits where candidate.pid == pid {
            ended = candidate
            break
        }
        #expect(ended == CEFChildProcessMonitor.Exit(pid: pid, processType: "utility", subType: "network.mojom.NetworkService",
                                                     isExtension: false, status: 3 << 8))
    }

    @Test func argvWithoutATypeIsNotAHelper() {
        #expect(CEFHelperIdentity.parse(["/bin/sh", "-c", "true"]) == nil)
        #expect(CEFHelperIdentity.parse(["helper", "--type=renderer", "--extension-process"])
            == CEFHelperIdentity(processType: "renderer", subType: nil, isExtension: true))
    }
}
