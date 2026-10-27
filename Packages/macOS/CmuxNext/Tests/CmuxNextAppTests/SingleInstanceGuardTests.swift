import AppKit
@testable import CmuxNextApp
import Foundation
import Testing

/// One copy of a cmux bundle per user session: a second copy (a direct exec from an ssh session, `open -n`)
/// hands off to the running one before Chromium or the session start (field log, 2026-10-26).
@Suite struct SingleInstanceGuardTests {
    private func guardFor(_ bundle: String? = "com.cmuxterm.app.nightly", environment: [String: String] = [:]) -> SingleInstanceGuard {
        SingleInstanceGuard(bundleIdentifier: bundle, pid: 200, uid: 501, environment: environment)
    }

    private func peer(_ pid: pid_t, uid: uid_t? = 501, launched: TimeInterval = 0, terminated: Bool = false) -> SingleInstanceGuard.Peer {
        SingleInstanceGuard.Peer(pid: pid, uid: uid, bundleURL: URL(filePath: "/Applications/cmux NIGHTLY.app"),
                                 launchDate: Date(timeIntervalSince1970: launched), isTerminated: terminated)
    }

    @Test func aSecondCopyOfTheSameBundleHandsOffToTheRunningOne() {
        #expect(guardFor().decide(peers: [peer(100), peer(200)]) == .handOff(peer(100), activates: true))
    }

    @Test func aLoneCopyLaunches() {
        #expect(guardFor().decide(peers: []) == .launch)
        #expect(guardFor().decide(peers: [peer(200)]) == .launch, "LaunchServices lists this process too")
    }

    @Test func anotherUsersCopyOrAnExitedOneDoesNotCount() {
        #expect(guardFor().decide(peers: [peer(100, uid: 502)]) == .launch, "fast user switching: another session's copy")
        #expect(guardFor().decide(peers: [peer(100, uid: nil)]) == .launch, "the kernel no longer has the pid")
        #expect(guardFor().decide(peers: [peer(100, terminated: true)]) == .launch, "a copy that already quit (Sparkle's relaunch)")
    }

    @Test func theOldestRunningCopyGetsTheHandOff() {
        #expect(guardFor().decide(peers: [peer(300, launched: 50), peer(100, launched: 10)]) == .handOff(peer(100, launched: 10), activates: true))
    }

    @Test func anAgentLaunchHandsOffWithoutActivating() {
        #expect(guardFor(environment: ["CMUX_NEXT_NO_ACTIVATE": "1"]).decide(peers: [peer(100)]) == .handOff(peer(100), activates: false))
    }

    @Test func devBundlesAndTheOptOutAreNotGuarded() {
        #expect(guardFor("com.cmuxterm.app.debug").decide(peers: [peer(100)]) == .launch)
        #expect(guardFor("com.cmuxterm.app.debug.my-tag").decide(peers: [peer(100)]) == .launch, "harnesses run a tagged bundle twice")
        #expect(guardFor("com.cmuxterm.app.staging").decide(peers: [peer(100)]) == .launch)
        #expect(guardFor(environment: [SingleInstanceGuard.allowKey: "1"]).decide(peers: [peer(100)]) == .launch)
        #expect(guardFor(nil).decide(peers: [peer(100)]) == .launch)
    }

    @Test func releaseChannelsAreGuarded() {
        for bundle in ["com.cmuxterm.app.next", "com.cmuxterm.app.nightly", "com.cmuxterm.app.rc"] {
            #expect(guardFor(bundle).decide(peers: [peer(100)]) == .handOff(peer(100), activates: true), "\(bundle)")
        }
    }

    @Test func filesGoAsOneOpenAndOtherURLsEachAsAGetURL() throws {
        let file = URL(filePath: "/tmp/a.md"), web = try #require(URL(string: "https://github.com/settings"))
        let link = try #require(URL(string: "cmux-nightly://open"))
        #expect(SingleInstanceHandoffEvents.events(for: [web, file, link], reopens: true)
            == [.openDocuments([file]), .getURL(web), .getURL(link)])
        #expect(SingleInstanceHandoffEvents.events(for: [], reopens: true) == [.reopen], "a bare launch brings the running copy forward")
        #expect(SingleInstanceHandoffEvents.events(for: [], reopens: false).isEmpty, "an agent launch never activates it")
    }

    @Test func theGetURLEventTargetsThePeersPid() throws {
        let web = try #require(URL(string: "https://github.com/settings"))
        let event = SingleInstanceHandoffEvents.descriptor(.getURL(web), to: 4242)
        #expect(event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue == web.absoluteString)
        let target = event.attributeDescriptor(forKeyword: AEKeyword(keyAddressAttr))
        #expect(target?.descriptorType == DescType(typeKernelProcessID))
    }
}
