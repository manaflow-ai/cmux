@testable import CmuxChief
import Foundation
import Testing

/// The `PATH` a Chief turn runs with: an app opened from the Dock or Finder
/// gets launchd's minimal `PATH`, so tools the user runs in Terminal (`gh`,
/// Homebrew installs) must still be found by the brain's shell commands.
@Suite struct ChiefSearchPathTests {
    let searchPath = ChiefSearchPath(home: "/Users/test")

    @Test func aMinimalAppPathGainsTheLoginShellPath() {
        let path = searchPath.merged(base: "/usr/bin:/bin:/usr/sbin:/sbin",
                                     loginShell: "/opt/homebrew/bin:/usr/bin:/bin:/custom/tools")
        let entries = path.split(separator: ":").map(String.init)
        #expect(Array(entries.prefix(4)) == ["/opt/homebrew/bin", "/usr/bin", "/bin", "/custom/tools"])
        #expect(entries.contains("/usr/sbin"))
        #expect(entries.count == Set(entries).count)
    }

    @Test func withoutALoginShellTheUsualInstallPlacesAreStillSearched() {
        let path = searchPath.merged(base: "/usr/bin:/bin:/usr/sbin:/sbin", loginShell: nil)
        let entries = path.split(separator: ":").map(String.init)
        #expect(Array(entries.prefix(4)) == ["/usr/bin", "/bin", "/usr/sbin", "/sbin"])
        for directory in ["/Users/test/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"] {
            #expect(entries.contains(directory))
        }
    }

    @Test func relativeAndUnexpandedEntriesAreDropped() {
        let path = searchPath.merged(base: "/usr/bin:.", loginShell: "$PATH:bin:/opt/homebrew/bin")
        let entries = path.split(separator: ":").map(String.init)
        #expect(entries.allSatisfy { $0.hasPrefix("/") })
        #expect(entries.first == "/opt/homebrew/bin")
    }

    @Test func theLoginShellReportIgnoresProfileChatter() {
        let marker = ChiefLoginShellPath.marker, end = ChiefLoginShellPath.endMarker
        #expect(ChiefLoginShellPath.parse("Welcome back!\n\(marker)/opt/homebrew/bin:/usr/bin\(end)\n")
            == "/opt/homebrew/bin:/usr/bin")
        #expect(ChiefLoginShellPath.parse("no marker here") == nil)
        #expect(ChiefLoginShellPath.parse("\(marker)/usr/bin") == nil)
        #expect(ChiefLoginShellPath.parse("\(marker)   \(end)") == nil)
    }

    @Test func shellsThatRejectTheLookupAreSkipped() {
        #expect(ChiefLoginShellPath.supports("/bin/zsh"))
        #expect(ChiefLoginShellPath.supports("/opt/homebrew/bin/fish"))
        #expect(!ChiefLoginShellPath.supports("/bin/tcsh"))
        #expect(!ChiefLoginShellPath.supports("/bin/csh"))
        #expect(!ChiefLoginShellPath.supports("/opt/homebrew/bin/nu"))
    }

    /// A profile that leaves a background child holding the shell's stdout
    /// must not keep the lookup (and so every turn) waiting.
    @Test(.timeLimit(.minutes(1))) func aBackgroundChildOfTheProfileDoesNotHoldTheLookup() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chief-shell-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let shell = directory.appendingPathComponent("sh")
        let childPID = directory.appendingPathComponent("child.pid")
        try """
        #!/bin/sh
        tail -f /dev/null &
        echo $! > '\(childPID.path)'
        exec /bin/sh "$@"
        """.write(to: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell.path)
        defer {
            let text = (try? String(contentsOf: childPID, encoding: .utf8)) ?? ""
            if let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) { kill(pid, SIGKILL) }
        }
        let path = await ChiefLoginShellPath.run(shell: shell.path, timeout: .seconds(30))
        #expect(path?.isEmpty == false)
    }

    @Test func aFailedLookupIsRetriedOnce() async {
        let runs = RunCounter(results: [nil, "/opt/homebrew/bin"])
        let lookup = ChiefLoginShellPath { await runs.next() }
        #expect(await lookup.value() == nil)
        #expect(await lookup.value() == "/opt/homebrew/bin")
        #expect(await lookup.value() == "/opt/homebrew/bin")
        #expect(await runs.count == 2)
    }

    @Test func aLookupThatKeepsFailingStopsRunning() async {
        let runs = RunCounter(results: [nil, nil, "/opt/homebrew/bin"])
        let lookup = ChiefLoginShellPath { await runs.next() }
        #expect(await lookup.value() == nil)
        #expect(await lookup.value() == nil)
        #expect(await lookup.value() == nil)
        #expect(await runs.count == 2)
    }

    @Test func theLoginShellRunsOncePerApp() async {
        let runs = RunCounter()
        let lookup = ChiefLoginShellPath { await runs.next() }
        async let first = lookup.value()
        async let second = lookup.value()
        #expect(await first == "/opt/homebrew/bin:/usr/bin")
        #expect(await second == "/opt/homebrew/bin:/usr/bin")
        #expect(await lookup.value() == "/opt/homebrew/bin:/usr/bin")
        #expect(await runs.count == 1)
    }
}

private actor RunCounter {
    private(set) var count = 0

    private var results: [String?]

    init(results: [String?] = ["/opt/homebrew/bin:/usr/bin"]) {
        self.results = results
    }

    func next() -> String? {
        count += 1
        return results.count > 1 ? results.removeFirst() : results.first ?? nil
    }
}
