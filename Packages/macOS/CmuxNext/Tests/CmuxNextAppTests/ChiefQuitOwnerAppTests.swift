import Foundation
import Testing
@testable import CmuxNextDaemon
@testable import CmuxNextHomeEngine

/// cp/quit-chief-idle (2026-10-27): a Cmd-Q left the Chief's brain host, its acpmux and its
/// conversation owner running, idle (about 300 MB). Each needs this app's pid to stop after the
/// app exits (optchat-chief owner_app.rs, cmux-tui headless/chief_owner_exit.rs), and the pid file
/// lets a helper an earlier app started follow this one.
struct ChiefQuitOwnerAppTests {
    private let pid = String(ProcessInfo.processInfo.processIdentifier)

    private func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("chief-quit-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func theBrainHostIsToldWhichAppItServes() throws {
        let base = root()
        let bin = base.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let chief = bin.appendingPathComponent(HomeBrainHost.bundledChiefName)
        try "#!/bin/sh\n".write(to: chief, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: chief.path)
        let home = ChiefHome(root: base.appendingPathComponent("chief", isDirectory: true), isolated: false,
                             buildID: "com.cmuxterm.app.debug.chiefquit")
        let host = try #require(HomeBrainHost.resolve(daemonSocket: "/tmp/owner.sock", controlSocket: "/tmp/app.sock", home: home,
                                                      environment: [:], bundledBinDirectory: bin, bundledChiefAllowed: true))
        #expect(host.childEnvironment["OPTCHAT_OWNER_APP_PID"] == pid)
    }

    @Test func theChiefOwnerIsToldWhichAppStartedIt() {
        let home = ChiefHome(root: root(), isolated: false)
        let environment = ChiefConversationOwner.ownerEnvironment(home: home, process: ["HOME": "/Users/x"])
        #expect(environment["CMUX_TUI_OWNER_APP_PID"] == pid)
        // `server ensure` passes it on to the owner it starts.
        #expect(DaemonLauncher.chiefEnvironment(environment)["CMUX_TUI_OWNER_APP_PID"] == pid)
    }

    @Test func theAppNamesItselfInTheChiefHome() throws {
        let home = ChiefHome(root: root(), isolated: false)
        home.recordOwnerApp(pid: 4242)
        let text = try String(contentsOf: home.ownerAppFile, encoding: .utf8)
        #expect(text == "4242\n")
        #expect(home.ownerAppFile.path.hasSuffix("/state/owner-app.pid"))
    }
}
