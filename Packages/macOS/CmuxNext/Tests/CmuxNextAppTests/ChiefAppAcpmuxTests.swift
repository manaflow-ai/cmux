import Foundation
import Testing
import CmuxNextCompat
@testable import CmuxNextAgentPane
@testable import CmuxNextHomeEngine

/// Leo, 2026-10-20: one acpmux per machine. NIGHTLY's Chief runs on the app's own acpmux
/// (`~/.acpmux`), and its host only waits for that daemon (`OPTCHAT_ACPMUX_SUPERVISED=1`): it
/// never starts or stops it. Any other build's Chief keeps the acpmux of its own Chief home.
struct ChiefAppAcpmuxTests {
    private struct Fixture {
        let bin: URL
        let acpmuxRoot: URL
        let chiefRoot: URL
    }

    private func fixture() throws -> Fixture {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("chief-app-acpmux-\(UUID().uuidString)")
        let bin = base.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for name in [HomeBrainHost.bundledChiefName, "acpmux"] {
            let file = bin.appendingPathComponent(name)
            try "#!/bin/sh\n".write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        return Fixture(bin: bin, acpmuxRoot: base.appendingPathComponent("acpmux-root", isDirectory: true),
                       chiefRoot: base.appendingPathComponent("chief/default", isDirectory: true))
    }

    private func host(_ fixture: Fixture, buildID: String, appBuild: BuildIdentity? = nil) -> HomeBrainHost? {
        let home = ChiefHome(root: fixture.chiefRoot, isolated: false, buildID: buildID)
        return HomeBrainHost.resolve(daemonSocket: "/tmp/owner.sock", controlSocket: "/tmp/app.sock", home: home, appBuild: appBuild,
                                     environment: ["CMUX_NEXT_ACPMUX_ROOT": fixture.acpmuxRoot.path],
                                     bundledBinDirectory: fixture.bin, bundledChiefAllowed: true)
    }

    @Test func nightlysChiefRunsOnTheAppsAcpmuxAndOnlyWaitsForIt() throws {
        let fixture = try fixture()
        let host = try #require(self.host(fixture, buildID: ChiefHome.nightlyBundleID))
        #expect(host.acpmux?.home.standardizedFileURL == fixture.acpmuxRoot.standardizedFileURL)
        let environment = host.childEnvironment
        #expect(environment["ACPMUX_HOME"] == fixture.acpmuxRoot.path)
        #expect(environment["OPTCHAT_ACPMUX_SUPERVISED"] == "1")
        // Never the shared mode: its last Chief to leave ends every session of the daemon.
        #expect(environment["OPTCHAT_ACPMUX_SHARED"] == nil)
    }

    // A Debug compile running as NIGHTLY (`CMUX_NEXT_CHIEF_BUILD_ID`) resolves the daemon its
    // own panes use, the app's build's, never another one.
    @Test func theChiefResolvesTheDaemonOfTheAppsBuild() throws {
        let fixture = try fixture()
        let build = BuildIdentity(bundleID: "com.cmuxterm.app.debug.chiefbase", bundledTag: "chiefbase")
        let host = try #require(self.host(fixture, buildID: ChiefHome.nightlyBundleID, appBuild: build))
        let panes = AcpmuxEnvironment.resolve(build: build, bundledBinDirectory: fixture.bin,
                                              environment: ["CMUX_NEXT_ACPMUX_ROOT": fixture.acpmuxRoot.path])
        #expect(host.acpmux?.home.standardizedFileURL == panes?.home.standardizedFileURL)
        #expect(host.acpmux?.socketPath == panes?.socketPath)
    }

    @Test func anotherBuildsChiefKeepsItsOwnAcpmux() throws {
        let fixture = try fixture()
        let host = try #require(self.host(fixture, buildID: "com.cmuxterm.app.debug.chiefbase"))
        let own = fixture.chiefRoot.appendingPathComponent("acpmux", isDirectory: true)
        #expect(host.acpmux?.home.standardizedFileURL == own.standardizedFileURL)
        #expect(host.childEnvironment["ACPMUX_HOME"] == own.path)
        #expect(host.childEnvironment["OPTCHAT_ACPMUX_SUPERVISED"] == nil)
    }

    @Test func onlyNightlysOwnHomeUsesTheAppsAcpmux() {
        let nightly = ChiefHome.nightlyBundleID
        #expect(ChiefHome.usesAppAcpmux(isolated: false, buildID: nightly, ownAcpmux: false))
        // `CMUX_CHIEF_OWN_ACPMUX=1` brings the Chief's own daemon back.
        #expect(!ChiefHome.usesAppAcpmux(isolated: false, buildID: nightly, ownAcpmux: true))
        #expect(ChiefHome.ownAcpmux(["CMUX_CHIEF_OWN_ACPMUX": "1"]))
        #expect(!ChiefHome.ownAcpmux(["CMUX_CHIEF_OWN_ACPMUX": "0"]))
        #expect(!ChiefHome.ownAcpmux([:]))
        #expect(!ChiefHome.usesAppAcpmux(isolated: true, buildID: nightly, ownAcpmux: false))
        #expect(!ChiefHome.usesAppAcpmux(isolated: false, buildID: nil, ownAcpmux: false))
        #expect(!ChiefHome.usesAppAcpmux(isolated: false, buildID: "com.cmuxterm.app.nightly.cmux-next", ownAcpmux: false))
    }

    // An update relaunch does not stop the Chief host: one this app did not launch on the app's
    // acpmux (the previous build's, on the Chief's own daemon) or whose executable is gone is
    // restarted, and the Chief's own daemon ends unless a named Chief still runs on it.
    @Test func aHostFromBeforeTheMoveIsRestartedAndItsDaemonEnds() {
        let app = "/Users/me/.acpmux"
        let move = { (pid: pid_t?, replaced: Bool, marked: pid_t?, home: String?, present: Bool, named: Bool) in
            ChiefAppAcpmuxMove.plan(hostPID: pid, hostReplaced: replaced, markedPID: marked, markedHome: home, appHome: app,
                                    ownDaemonPresent: present, namedChiefsRun: named)
        }
        // The previous build's host: no launch mark.
        #expect(move(41, false, nil, nil, true, false) == .init(restartHost: true, endOwnDaemon: true))
        // A mark of an earlier host, or of another acpmux home (`CMUX_CHIEF_OWN_ACPMUX` was on).
        #expect(move(41, false, 40, app, false, false).restartHost)
        #expect(move(41, false, 41, "/Users/me/.cmux/chief/default/acpmux", false, false).restartHost)
        // This app's host on the app's acpmux, but its bundle was replaced by an update.
        #expect(move(41, true, 41, app, false, false).restartHost)
        // This app's host on the app's acpmux stays; a leftover Chief daemon still ends.
        #expect(move(41, false, 41, app, false, false) == .init())
        #expect(move(41, false, 41, app, true, false) == .init(restartHost: false, endOwnDaemon: true))
        // A named Chief of the home still runs on that daemon: it keeps running.
        #expect(move(nil, false, nil, nil, true, true) == .init())
    }

    // The old Chief daemon ends with its agents only when none of them is in a turn: a subagent
    // the Chief started may still be working after the Chief itself went idle.
    @Test func theOldChiefDaemonEndsOnlyWhenNoSessionIsInATurn() {
        #expect(ChiefAppAcpmuxMove.idle(AcpmuxSessionCensus(live: 3)))
        #expect(!ChiefAppAcpmuxMove.idle(AcpmuxSessionCensus(live: 3, inTurn: 1, inTurnNames: ["lane"])))
        #expect(!ChiefAppAcpmuxMove.idle(AcpmuxSessionCensus(live: 1, chiefInTurn: true)))
        // A daemon that did not answer the census in time may be busy: it is not ended.
        #expect(!ChiefAppAcpmuxMove.idle(nil))
    }

    // End Sessions ends the Chief's agents too: on the app's acpmux they run beside the person's,
    // so the app's end keeps none of them; on its own daemon that one ends them.
    @Test func endSessionsOnTheAppsAcpmuxKeepsNoChiefAgent() {
        #expect(ChiefHostStop.appAcpmuxEndKeep(chiefUsesAppAcpmux: true) == .nothing)
        #expect(ChiefHostStop.appAcpmuxEndKeep(chiefUsesAppAcpmux: false) == .chief)
    }

    // `CMUX_CHIEF_OWN_ACPMUX=1` takes effect at the next launch: the host this app launched on the
    // app's acpmux restarts on the Chief home's own daemon, where the Chief's tabs then attach.
    @Test func theKillSwitchRestartsAHostOnTheAppsAcpmux() {
        let own = "/Users/me/.cmux/chief/default/acpmux"
        let onApp = { (pid: pid_t?, marked: pid_t?, home: String?) in
            ChiefAppAcpmuxMove.onAppAcpmux(hostPID: pid, markedPID: marked, markedHome: home, ownHome: own)
        }
        #expect(onApp(41, 41, "/Users/me/.acpmux"))
        // No host, an older host than the mark's, no mark, or a host on its own daemon: nothing to move.
        #expect(!onApp(nil, 41, "/Users/me/.acpmux"))
        #expect(!onApp(42, 41, "/Users/me/.acpmux"))
        #expect(!onApp(41, nil, nil))
        #expect(!onApp(41, 41, own))
    }
}
