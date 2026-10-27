import AppKit
@testable import CmuxNextUpdater
import Foundation
import Testing

/// One copy of a cmux bundle per user: a second copy (a direct exec from an ssh session, `open -n`) hands off to
/// the running one before Chromium or the session start (field log, 2026-10-26).
@Suite struct SingleInstanceGuardTests {
    private func guardFor(_ bundle: String? = "com.cmuxterm.app.nightly", environment: [String: String] = [:]) -> SingleInstanceGuard {
        SingleInstanceGuard(bundleIdentifier: bundle, environment: environment)
    }

    @Test func aSecondCopyNeverStarts() {
        #expect(guardFor().decide(.taken) == .handOff(activates: true))
    }

    @Test func theOwnerAndUnclaimableLaunchesStart() {
        #expect(guardFor().decide(.held) == .launch)
        #expect(guardFor().decide(.unavailable) == .launch, "no lock file: launch as before")
    }

    @Test func anAgentLaunchHandsOffWithoutActivating() {
        #expect(guardFor(environment: ["CMUX_NEXT_NO_ACTIVATE": "1"]).decide(.taken) == .handOff(activates: false))
    }

    @Test func devBundlesAndTheOptOutAreNotGuarded() {
        for bundle in ["com.cmuxterm.app.debug", "com.cmuxterm.app.debug.my-tag", "com.cmuxterm.app.staging"] {
            #expect(!guardFor(bundle).isGuarded, "\(bundle): harnesses run a tagged bundle twice")
            #expect(guardFor(bundle).decide(.taken) == .launch)
        }
        #expect(guardFor(environment: [SingleInstanceGuard.allowKey: "1"]).decide(.taken) == .launch)
        #expect(guardFor(nil).decide(.taken) == .launch)
    }

    @Test func releaseChannelsAreGuarded() {
        for bundle in ["com.cmuxterm.app.next", "com.cmuxterm.app.nightly", "com.cmuxterm.app"] {
            #expect(guardFor(bundle).decide(.taken) == .handOff(activates: true), "\(bundle)")
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
        #expect(SingleInstanceGuard.claim(at: url) == .taken)
        #expect(!SingleInstanceGuard.isFree(at: url))
        #expect(SingleInstanceGuard.owner(at: url) == nil, "this process's own pid is never an owner to hand to")
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

    @Test func theOwnerIsReadFromTheClaimAndAFreedClaimIsFree() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "single-instance-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "instance.lock")
        try Data("4242\n".utf8).write(to: url)
        #expect(SingleInstanceGuard.owner(at: url) == 4242)
        #expect(SingleInstanceGuard.isFree(at: url), "nobody holds it: its owner ended")
    }

    /// A retry never repeats an open the owner already answered (each open makes a tab).
    @Test func aRetrySendsOnlyWhatWasNotAnswered() throws {
        let a = try #require(URL(string: "https://a.example/")), b = try #require(URL(string: "https://b.example/"))
        var queue = SingleInstanceHandoffQueue()
        #expect(queue.pending == [.reopen], "a bare launch brings the owner forward")
        queue.add([a, b])
        #expect(queue.pending == [.getURL(a), .getURL(b)], "URLs replace the bare launch's reopen")
        var sent: [SingleInstanceHandoffEvents.Event] = []
        queue.drain { sent.append($0); return $0 == .getURL(a) }  // a answered, b not
        #expect(sent == [.getURL(a), .getURL(b)])
        #expect(queue.pending == [.getURL(b)])
        #expect(queue.unansweredURLs == [b], "a reopen through LaunchServices carries only b")
        sent = []
        queue.drain { sent.append($0); return true }
        #expect(sent == [.getURL(b)], "the retry sends only b")
        #expect(queue.isDone)
    }

    @Test func aFailedFirstEventStopsThePass() {
        var queue = SingleInstanceHandoffQueue()
        var calls = 0
        queue.drain { _ in calls += 1; return false }
        #expect(calls == 1)
        #expect(queue.pending == [.reopen])
        #expect(queue.unansweredURLs.isEmpty)
    }

    /// A slow first batch (each event waits its whole budget) still ends by the give-up instant, so the recovery
    /// there runs before the hard exit.
    @MainActor @Test func sendsNeverRunPastTheGiveUpInstant() {
        let start = ContinuousClock.now
        let giveUpAt = start + .seconds(SingleInstanceHandoff.deadline)
        var now = start + .milliseconds(1500)  // AppKit's start was slow
        var sent = 0
        while let wait = SingleInstanceHandoff.replyBudget(now: now, giveUpAt: giveUpAt) {
            #expect(wait <= SingleInstanceHandoff.replyWait)
            now = now + .seconds(wait)  // no reply: the whole wait is spent
            sent += 1
        }
        #expect(now <= giveUpAt)
        #expect(sent == 3, "1 s, 1 s, then the last 0.5 s")
        #expect(SingleInstanceHandoff.hardDeadline - SingleInstanceHandoff.deadline >= 1, "the recovery keeps its time")
        #expect(SingleInstanceHandoff.replyBudget(now: giveUpAt - .milliseconds(10), giveUpAt: giveUpAt) == nil)
    }

    @Test func theGetURLEventTargetsTheOwnersPid() throws {
        let web = try #require(URL(string: "https://github.com/settings"))
        let event = SingleInstanceHandoffEvents.descriptor(.getURL(web), to: 4242)
        #expect(event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue == web.absoluteString)
        let target = event.attributeDescriptor(forKeyword: AEKeyword(keyAddressAttr))
        #expect(target?.descriptorType == DescType(typeKernelProcessID))
    }
}
