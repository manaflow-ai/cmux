import AppKit
@testable import CmuxNextApp
import Foundation
import Testing

/// One copy of a cmux bundle per user: a second copy (a direct exec from an ssh session, `open -n`) hands off to
/// the running one before Chromium or the session start (field log, 2026-10-26).
@Suite struct SingleInstanceGuardTests {
    private func guardFor(_ bundle: String? = "com.cmuxterm.app.nightly", environment: [String: String] = [:]) -> SingleInstanceGuard {
        SingleInstanceGuard(bundleIdentifier: bundle, environment: environment)
    }

    @Test func aSecondCopyHandsOffToTheClaimsOwner() {
        #expect(guardFor().decide(.taken(owner: 100)) == .handOff(owner: 100, activates: true))
    }

    @Test func theOwnerAndUnclaimableLaunchesStart() {
        #expect(guardFor().decide(.held) == .launch)
        #expect(guardFor().decide(.unavailable) == .launch, "no lock file: launch as before")
        #expect(guardFor().decide(.taken(owner: nil)) == .launch, "no owner pid to hand to: never lose the launch")
        #expect(guardFor().decide(.taken(owner: getpid())) == .launch)
    }

    @Test func anAgentLaunchHandsOffWithoutActivating() {
        #expect(guardFor(environment: ["CMUX_NEXT_NO_ACTIVATE": "1"]).decide(.taken(owner: 100)) == .handOff(owner: 100, activates: false))
    }

    @Test func devBundlesAndTheOptOutAreNotGuarded() {
        for bundle in ["com.cmuxterm.app.debug", "com.cmuxterm.app.debug.my-tag", "com.cmuxterm.app.staging"] {
            #expect(!guardFor(bundle).isGuarded, "\(bundle): harnesses run a tagged bundle twice")
            #expect(guardFor(bundle).decide(.taken(owner: 100)) == .launch)
        }
        #expect(guardFor(environment: [SingleInstanceGuard.allowKey: "1"]).decide(.taken(owner: 100)) == .launch)
        #expect(guardFor(nil).decide(.taken(owner: 100)) == .launch)
    }

    @Test func releaseChannelsAreGuarded() {
        for bundle in ["com.cmuxterm.app.next", "com.cmuxterm.app.nightly", "com.cmuxterm.app"] {
            #expect(guardFor(bundle).decide(.taken(owner: 100)) == .handOff(owner: 100, activates: true), "\(bundle)")
        }
    }

    /// The claim is a lifetime flock: a second descriptor (a second copy) finds it taken with the owner's pid,
    /// and gets it once the owner lets go (the kernel releases it when the owner process ends).
    @Test func theClaimIsExclusiveAndNamesItsOwner() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "single-instance-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "instance.lock")
        #expect(SingleInstanceGuard.claim(at: url) == .held)
        // flock is per open file description: a new open in this process stands in for a second copy.
        let other = open(url.path, O_RDWR | O_CLOEXEC)
        defer { close(other) }
        #expect(flock(other, LOCK_EX | LOCK_NB) != 0, "held by the first descriptor")
        #expect(SingleInstanceGuard.claim(at: url, ownerWait: 0) == .taken(owner: getpid()))
    }

    @Test func eachBundleHasItsOwnLock() throws {
        let support = URL(filePath: "/tmp/support")
        #expect(SingleInstanceGuard.lockURL(bundleIdentifier: "com.cmuxterm.app.nightly", applicationSupport: support)?.path
            == "/tmp/support/com.cmuxterm.app.nightly/instance.lock")
        #expect(SingleInstanceGuard.lockURL(bundleIdentifier: "com.cmuxterm.app.next", applicationSupport: support)
            != SingleInstanceGuard.lockURL(bundleIdentifier: "com.cmuxterm.app.nightly", applicationSupport: support))
    }

    @Test func filesGoAsOneOpenAndOtherURLsEachAsAGetURL() throws {
        let file = URL(filePath: "/tmp/a.md"), web = try #require(URL(string: "https://github.com/settings"))
        let link = try #require(URL(string: "cmux-nightly://open"))
        #expect(SingleInstanceHandoffEvents.events(for: [web, file, link]) == [.openDocuments([file]), .getURL(web), .getURL(link)])
        #expect(SingleInstanceHandoffEvents.events(for: []).isEmpty)
    }

    @Test func theGetURLEventTargetsTheOwnersPid() throws {
        let web = try #require(URL(string: "https://github.com/settings"))
        let event = SingleInstanceHandoffEvents.descriptor(.getURL(web), to: 4242)
        #expect(event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue == web.absoluteString)
        let target = event.attributeDescriptor(forKeyword: AEKeyword(keyAddressAttr))
        #expect(target?.descriptorType == DescType(typeKernelProcessID))
    }
}
