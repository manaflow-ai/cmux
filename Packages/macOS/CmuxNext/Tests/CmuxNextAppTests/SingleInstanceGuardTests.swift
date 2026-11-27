import AppKit
import Darwin
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

    /// The claim is a lifetime flock: a second descriptor (a second copy) finds it taken.
    @Test func theClaimIsExclusive() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "single-instance-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "instance.lock")
        #expect(SingleInstanceGuard.claim(at: url) == .held)
        // flock is per open file description: a new open in this process stands in for a second copy.
        let other = open(url.path, O_RDWR | O_CLOEXEC)
        defer { close(other) }
        #expect(flock(other, LOCK_EX | LOCK_NB) != 0, "held by the first descriptor")
        #expect(SingleInstanceGuard.claim(at: url) == .taken)
    }

    @Test func eachBundleHasItsOwnLock() throws {
        let support = URL(filePath: "/tmp/support")
        #expect(SingleInstanceGuard.lockURL(bundleIdentifier: "com.cmuxterm.app.nightly", applicationSupport: support)?.path
            == "/tmp/support/com.cmuxterm.app.nightly/instance.lock")
        #expect(SingleInstanceGuard.lockURL(bundleIdentifier: "com.cmuxterm.app.next", applicationSupport: support)
            != SingleInstanceGuard.lockURL(bundleIdentifier: "com.cmuxterm.app.nightly", applicationSupport: support))
    }

    /// The helper waits on the second copy's exit, then hands its URLs (files as paths) to the running copy's own
    /// bundle through LaunchServices. `$0` is the pid and `$1` the bundle path; `shift` leaves only the URLs.
    @Test func theReopenHelperOpensTheURLsWithTheRunningBundleAfterThisPidExits() throws {
        let web = try #require(URL(string: "https://github.com/settings"))
        let file = URL(filePath: "/tmp/a b.md")
        let command = SingleInstanceHandoff.reopenCommand(pid: 4242, appPath: "/Applications/cmux NEXT.app", urls: [web, file])
        #expect(command[0] == "/bin/sh")
        #expect(command[1] == "-c")
        #expect(command[2].contains("caffeinate -w \"$p\""))
        #expect(command[2].contains("open -a \"$a\" \"$@\""))
        #expect(!command[2].contains("open -b"), "never a lookup by bundle id")
        #expect(Array(command[3...]) == ["4242", "/Applications/cmux NEXT.app", "https://github.com/settings", "/tmp/a b.md"])
    }

    /// Runs the helper with an exited pid (it goes straight on) and `open` replaced by `echo`; returns its argv.
    private func helperArguments(appPath: String, urls: [URL]) throws -> String {
        var command = SingleInstanceHandoff.reopenCommand(pid: 999_999, appPath: appPath, urls: urls)
        command[2] = command[2].replacingOccurrences(of: "/usr/bin/caffeinate -w \"$p\"; exec /usr/bin/open", with: "exec /bin/echo")
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(filePath: command[0])
        process.arguments = Array(command.dropFirst())
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    /// The helper really runs and passes only the bundle and the URLs.
    @Test func theReopenHelperPassesOnlyTheURLs() throws {
        let output = try helperArguments(appPath: "/Applications/cmux.app", urls: [try #require(URL(string: "https://a.example/"))])
        #expect(output == "-a /Applications/cmux.app https://a.example/\n")
    }

    private func ownerFile() -> (directory: URL, url: URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "single-instance-\(UUID().uuidString)")
        return (directory, SingleInstanceGuard.ownerURL(lockURL: directory.appending(path: "instance.lock")))
    }

    private typealias Identity = SingleInstanceGuard.Identity

    /// Nightly proof, 2026-10-27: the bundle id resolved to an older copy (`/Users/Shared/.../cmux NEXT DAILY.app`,
    /// no guard) while another copy held the claim; `open -b` started the older one, whose Chromium failed. The
    /// helper goes to the path the claim's owner recorded, whatever the bundle id resolves to.
    @Test func theHandOffTargetsTheRunningCopyNotWhatTheBundleIdResolvesTo() throws {
        let (directory, url) = ownerFile()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let runningIdentity = Identity(executablePath: "/Applications/cmux NEXT.app/Contents/MacOS/cmux", started: "1793137000.5")
        let running = SingleInstanceGuard.Owner(pid: 58353, bundlePath: "/Applications/cmux NEXT.app", identity: runningIdentity)
        let launchServicesPick = "/Users/Shared/cmux-capture/dailyuse/cmux NEXT DAILY.app"
        SingleInstanceGuard.writeOwner(running, at: url)
        let resolved = try #require(SingleInstanceGuard.runningCopy(at: url, selfPID: 59556) { pid in
            pid == 58353 ? runningIdentity : Identity(executablePath: "\(launchServicesPick)/Contents/MacOS/cmux", started: "1")
        })
        #expect(resolved == running)
        let output = try helperArguments(appPath: resolved.bundlePath, urls: [try #require(URL(string: "https://maps.google.com/"))])
        #expect(output == "-a /Applications/cmux NEXT.app https://maps.google.com/\n")
        #expect(!output.contains(launchServicesPick))
        // A bare launch (no URLs) brings that same copy forward.
        #expect(try helperArguments(appPath: resolved.bundlePath, urls: []) == "-a /Applications/cmux NEXT.app\n")
    }

    /// A record that no longer names a live copy (the pid ended, or was reused, even by the same executable started
    /// later; this very process; a missing, oversized or garbled file) resolves to nothing, so nothing launches.
    @Test func anUnprovableOwnerResolvesToNothing() throws {
        let (directory, url) = ownerFile()
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = Identity(executablePath: "/Applications/cmux.app/Contents/MacOS/cmux", started: "1793137000.5")
        #expect(SingleInstanceGuard.runningCopy(at: url, selfPID: 1) { _ in identity } == nil, "no record (owner not written yet)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let owner = SingleInstanceGuard.Owner(pid: 4242, bundlePath: "/Applications/cmux.app", identity: identity)
        SingleInstanceGuard.writeOwner(owner, at: url)
        #expect(SingleInstanceGuard.runningCopy(at: url, selfPID: 1) { _ in identity } == owner)
        #expect(SingleInstanceGuard.runningCopy(at: url, selfPID: 1) { _ in nil } == nil, "pid ended")
        #expect(SingleInstanceGuard.runningCopy(at: url, selfPID: 1) { _ in Identity(executablePath: "/usr/bin/vim", started: "1793137000.5") }
            == nil, "pid reused by another program")
        #expect(SingleInstanceGuard.runningCopy(at: url, selfPID: 1) { _ in Identity(executablePath: identity.executablePath, started: "1793137900.1") }
            == nil, "pid reused by another copy of the same executable")
        #expect(SingleInstanceGuard.runningCopy(at: url, selfPID: 4242) { _ in identity } == nil, "itself")
        try Data((owner.record + String(repeating: "x", count: 70 * 1024)).utf8).write(to: url)
        #expect(SingleInstanceGuard.runningCopy(at: url, selfPID: 1) { _ in identity } == nil, "oversized")
        #expect(SingleInstanceGuard.Owner(record: "") == nil)
        #expect(SingleInstanceGuard.Owner(record: "abc\n/a.app\n/a\n1.0\n") == nil)
        #expect(SingleInstanceGuard.Owner(record: "42\n/a.app\n/a\n") == nil, "no start time")
        #expect(SingleInstanceGuard.Owner(record: owner.record) == owner)
    }

    /// The real lookups: the kernel's start time of this process is stable and a pid nobody has gets none; a pid no
    /// application has resolves to nothing; this test process, when LaunchServices knows it as an application,
    /// resolves as an owner, and a new record replaces a longer stale one whole.
    @Test func theLiveLookupNamesOnlyTheRecordedProcess() throws {
        let started = try #require(SingleInstanceGuard.processStartTime(getpid()))
        #expect(SingleInstanceGuard.processStartTime(getpid()) == started)
        #expect(SingleInstanceGuard.processStartTime(99_999_999) == nil)
        #expect(SingleInstanceGuard.processIdentity(99_999_999) == nil)
        let (directory, url) = ownerFile()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(String(repeating: "stale record\n", count: 50).utf8).write(to: url)
        guard let identity = SingleInstanceGuard.processIdentity(getpid()) else { return }  // a bare test runner
        #expect(identity.started == started)
        let owner = SingleInstanceGuard.Owner(pid: getpid(), bundlePath: "/Applications/cmux.app", identity: identity)
        SingleInstanceGuard.writeOwner(owner, at: url)
        #expect(SingleInstanceGuard.runningCopy(at: url, selfPID: 0) == owner)
    }

    /// The record sits beside the lock, so the lock's flock never guards a file a reader opens.
    @Test func theOwnerRecordIsBesideTheLock() {
        #expect(SingleInstanceGuard.ownerURL(lockURL: URL(filePath: "/tmp/support/com.cmuxterm.app.nightly/instance.lock")).path
            == "/tmp/support/com.cmuxterm.app.nightly/instance.owner")
    }
}
