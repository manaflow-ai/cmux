import Foundation
import Testing
@testable import CmuxNextRemoteBrowser
import CmuxNextRemoteView

#if DEBUG
/// The app side of the local host launch contract (the host's launch.rs):
/// the locator, the readiness line, and a real child process that follows
/// the contract (a shell script stands in for the CEF host).
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct LocalRemoteBrowserHostTests {
    /// The same literal as the host's `listening_line_matches_the_app_vector`.
    @Test func parsesListeningLine() throws {
        let listening = try #require(RemoteBrowserHostListening(line: #"{"listening":"127.0.0.1:52144"}"#))
        #expect(listening.endpoint.port == 52144)
    }

    @Test func refusesOtherLinesAndHosts() {
        #expect(RemoteBrowserHostListening(line: "serve: listening on 127.0.0.1:52144") == nil)
        #expect(RemoteBrowserHostListening(line: #"{"listening":"10.0.0.2:52144"}"#) == nil)
        #expect(RemoteBrowserHostListening(line: #"{"listening":"localhost:52144"}"#) == nil)
        #expect(RemoteBrowserHostListening(line: #"{"listening":"127.0.0.1:80"}"#) == nil)
        #expect(RemoteBrowserHostListening(line: #"{"other":"127.0.0.1:52144"}"#) == nil)
    }

    @Test func serveArgumentsAskForAFreeLoopbackPortAndTheLifeline() throws {
        let page = try #require(URL(string: "https://example.com/a?b=c"))
        #expect(LocalRemoteBrowserHost.arguments(pageURL: page)
            == ["--serve", "--listen", "127.0.0.1:0", "--lifeline", "--url", "https://example.com/a?b=c"])
        #expect(LocalRemoteBrowserHost.arguments(pageURL: nil) == ["--serve", "--listen", "127.0.0.1:0", "--lifeline"])
    }

    @Test func locatorPrefersTheOverrideThenTheBundledApp() throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appending(path: "cmux DEV.app")
        let bundled = app.appending(path: LocalRemoteBrowserHostLocator.bundledAppPath)
            .appending(path: "Contents/MacOS/cmux-remote-browser-host")
        let custom = root.appending(path: "custom/cmux-remote-browser-host.app")
        let customExecutable = custom.appending(path: "Contents/MacOS/cmux-remote-browser-host")
        let bare = root.appending(path: "bin/cmux-remote-browser-host")

        // Nothing is there yet.
        #expect(LocalRemoteBrowserHostLocator(environment: [:], appBundle: app).executable() == nil)
        try Self.makeExecutable(bundled, script: "exit 0")
        #expect(LocalRemoteBrowserHostLocator(environment: [:], appBundle: app).executable()?.path == bundled.path)
        // An override that is not executable falls back to the bundled host.
        let missing = [LocalRemoteBrowserHostLocator.environmentKey: custom.path]
        #expect(LocalRemoteBrowserHostLocator(environment: missing, appBundle: app).executable()?.path == bundled.path)
        // An override `.app` names its executable; a bare path is the executable.
        try Self.makeExecutable(customExecutable, script: "exit 0")
        #expect(LocalRemoteBrowserHostLocator(environment: missing, appBundle: app).executable()?.path == customExecutable.path)
        try Self.makeExecutable(bare, script: "exit 0")
        let direct = [LocalRemoteBrowserHostLocator.environmentKey: bare.path]
        #expect(LocalRemoteBrowserHostLocator(environment: direct, appBundle: app).executable()?.path == bare.path)
        // An empty override is no override.
        let empty = [LocalRemoteBrowserHostLocator.environmentKey: ""]
        #expect(LocalRemoteBrowserHostLocator(environment: empty, appBundle: app).executable()?.path == bundled.path)
    }

    /// The fake host records its arguments and cache variable, prints the
    /// readiness line, and blocks on stdin; it exits 7 only at end of file.
    @Test func startReturnsAtTheListeningLineAndStopEndsTheHostThroughTheLifeline() async throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = root.appending(path: "record")
        let host = root.appending(path: "host")
        try Self.makeExecutable(host, script: """
        printf '%s\\n' "$@" > "\(record.path).args"
        printf '%s' "$CMUX_RB_CACHE_DIR" > "\(record.path).cache"
        echo 'serve: starting' >&2
        echo 'not the line'
        echo '{"listening":"127.0.0.1:52144"}'
        cat > /dev/null
        echo eof > "\(record.path).eof"
        exit 7
        """)
        let page = try #require(URL(string: "https://example.com/"))
        let started = try await LocalRemoteBrowserHost.start(executable: host, pageURL: page, workRoot: root)
        #expect(started.endpoint.port == 52144)
        let arguments = try String(contentsOf: URL(fileURLWithPath: record.path + ".args"), encoding: .utf8)
        #expect(arguments == "--serve\n--listen\n127.0.0.1:0\n--lifeline\n--url\nhttps://example.com/\n")
        let cache = try String(contentsOf: URL(fileURLWithPath: record.path + ".cache"), encoding: .utf8)
        #expect(cache.hasPrefix(root.path) && cache.hasSuffix("/cache"))
        #expect(FileManager.default.fileExists(atPath: cache))
        // Still running: the lifeline is open.
        #expect(!FileManager.default.fileExists(atPath: record.path + ".eof"))

        started.stop()
        started.stop()
        #expect(await started.exitStatus() == 7)
        #expect(FileManager.default.fileExists(atPath: record.path + ".eof"))
        // The work directory goes with the host; the log stays.
        #expect(!FileManager.default.fileExists(atPath: cache))
        let log = try String(contentsOf: started.logURL, encoding: .utf8)
        #expect(log.contains("serve: starting"))
    }

    @Test func aHostThatExitsBeforeListeningFailsWithItsLog() async throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = root.appending(path: "host")
        try Self.makeExecutable(host, script: """
        echo 'serve: CEF init failed' >&2
        echo 'serve: listening on 127.0.0.1:0'
        exit 3
        """)
        do {
            _ = try await LocalRemoteBrowserHost.start(executable: host, pageURL: nil, workRoot: root)
            Issue.record("start returned for a host that never listened")
        } catch let LocalRemoteBrowserHost.Failure.exitedBeforeListening(log) {
            let text = try String(contentsOf: log, encoding: .utf8)
            #expect(text.contains("CEF init failed"))
        }
    }

    @Test func aMissingExecutableFailsToLaunch() async throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: LocalRemoteBrowserHost.Failure.self) {
            _ = try await LocalRemoteBrowserHost.start(executable: root.appending(path: "absent"), pageURL: nil, workRoot: root)
        }
    }

    private static func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "rb-local-host-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func makeExecutable(_ url: URL, script: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n\(script)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
#endif
