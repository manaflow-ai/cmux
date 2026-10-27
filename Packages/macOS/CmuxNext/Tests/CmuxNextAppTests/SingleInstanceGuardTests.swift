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

    /// The helper waits on the second copy's exit, then hands its URLs (files as paths) to the bundle's running
    /// copy through LaunchServices. `$0` is the pid and `$1` the bundle id; `shift` leaves only the URLs.
    @Test func theReopenHelperOpensTheURLsWithThisBundleAfterThisPidExits() throws {
        let web = try #require(URL(string: "https://github.com/settings"))
        let file = URL(filePath: "/tmp/a b.md")
        let command = SingleInstanceHandoff.reopenCommand(pid: 4242, bundleIdentifier: "com.cmuxterm.app.nightly", urls: [web, file])
        #expect(command[0] == "/bin/sh")
        #expect(command[1] == "-c")
        #expect(command[2].contains("caffeinate -w \"$p\""))
        #expect(command[2].contains("open -b \"$b\" \"$@\""))
        #expect(Array(command[3...]) == ["4242", "com.cmuxterm.app.nightly", "https://github.com/settings", "/tmp/a b.md"])
    }

    /// The helper really runs: with an exited pid it goes straight on (here `open` is replaced by `echo`).
    @Test func theReopenHelperPassesOnlyTheURLs() throws {
        var command = SingleInstanceHandoff.reopenCommand(pid: 999_999, bundleIdentifier: "com.example.id",
                                                          urls: [try #require(URL(string: "https://a.example/"))])
        command[2] = command[2].replacingOccurrences(of: "/usr/bin/caffeinate -w \"$p\"; exec /usr/bin/open", with: "exec /bin/echo")
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(filePath: command[0])
        process.arguments = Array(command.dropFirst())
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(output == "-b com.example.id https://a.example/\n")
    }
}
