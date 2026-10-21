import Foundation
import Testing
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

    private func host(_ fixture: Fixture, buildID: String) -> HomeBrainHost? {
        let home = ChiefHome(root: fixture.chiefRoot, isolated: false, buildID: buildID)
        return HomeBrainHost.resolve(daemonSocket: "/tmp/owner.sock", controlSocket: "/tmp/app.sock", home: home,
                                     environment: ["CMUX_NEXT_ACPMUX_ROOT": fixture.acpmuxRoot.path],
                                     bundledBinDirectory: fixture.bin, bundledChiefAllowed: true)
    }

    @Test func nightlysChiefRunsOnTheAppsAcpmuxAndOnlyWaitsForIt() throws {
        let fixture = try fixture()
        let host = try #require(host(fixture, buildID: ChiefHome.nightlyBundleID))
        #expect(host.acpmux?.home.standardizedFileURL == fixture.acpmuxRoot.standardizedFileURL)
        let environment = host.childEnvironment
        #expect(environment["ACPMUX_HOME"] == fixture.acpmuxRoot.path)
        #expect(environment["OPTCHAT_ACPMUX_SUPERVISED"] == "1")
        // Never the shared mode: its last Chief to leave ends every session of the daemon.
        #expect(environment["OPTCHAT_ACPMUX_SHARED"] == nil)
    }

    @Test func anotherBuildsChiefKeepsItsOwnAcpmux() throws {
        let fixture = try fixture()
        let host = try #require(host(fixture, buildID: "com.cmuxterm.app.debug.chiefbase"))
        let own = fixture.chiefRoot.appendingPathComponent("acpmux", isDirectory: true)
        #expect(host.acpmux?.home.standardizedFileURL == own.standardizedFileURL)
        #expect(host.childEnvironment["ACPMUX_HOME"] == own.path)
        #expect(host.childEnvironment["OPTCHAT_ACPMUX_SUPERVISED"] == nil)
    }

    @Test func onlyNightlysOwnHomeUsesTheAppsAcpmux() {
        let nightly = ChiefHome.nightlyBundleID
        #expect(ChiefHome.usesAppAcpmux(isolated: false, buildID: nightly, ownAcpmux: false))
        // The Debug Settings toggle brings the Chief's own daemon back.
        #expect(!ChiefHome.usesAppAcpmux(isolated: false, buildID: nightly, ownAcpmux: true))
        #expect(!ChiefHome.usesAppAcpmux(isolated: true, buildID: nightly, ownAcpmux: false))
        #expect(!ChiefHome.usesAppAcpmux(isolated: false, buildID: nil, ownAcpmux: false))
        #expect(!ChiefHome.usesAppAcpmux(isolated: false, buildID: "com.cmuxterm.app.nightly.cmux-next", ownAcpmux: false))
    }
}
