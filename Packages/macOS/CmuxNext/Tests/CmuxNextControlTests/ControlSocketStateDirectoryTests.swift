import CmuxNextActions
@testable import CmuxNextControl
import Darwin
import Foundation
import Testing

/// A tagged build's control socket lives in the user's state folder, not in
/// `/tmp`, where a host's cleaner deleted it under a running app two nights
/// running (readiness soak, hq#1870). The old `/tmp` name stays a symlink for
/// tools that still use it.
@MainActor @Suite(.serialized) struct ControlSocketStateDirectoryTests {
    func launch(home: String) -> (LaunchIdentity, String) {
        let tag = "cnc\(UUID().uuidString.prefix(8).lowercased())"
        let identity = LaunchIdentity.resolve(bundleID: "com.cmuxterm.app.debug.\(tag)", bundledEnvironment: [:], processEnvironment: [:],
                                              isDebugBuild: true, home: URL(fileURLWithPath: home))
        return (identity, tag)
    }

    @Test func aTaggedSocketLivesInTheStateFolderWithALinkAtItsOldName() throws {
        let home = "/tmp/cnch-\(UUID().uuidString.prefix(8).lowercased())"
        defer { try? FileManager.default.removeItem(atPath: home) }
        let (identity, tag) = launch(home: home)
        let service = try ControlService.start(registry: ActionRegistry(catalog: []), settings: nil, launch: identity, environment: [:])
        let socketPath = "\(home)/.local/state/cmux/cmux-debug-\(tag).sock"
        let link = "/tmp/cmux-debug-\(tag).sock"

        var info = stat()
        #expect(lstat(socketPath, &info) == 0 && info.st_mode & S_IFMT == S_IFSOCK, "the socket is in the state folder")
        #expect(lstat("\(home)/.local/state/cmux", &info) == 0 && info.st_mode & 0o777 == 0o700, "the state folder is the user's alone")
        let identify = try LineClient(path: socketPath).call("system.identify")
        #expect(identify["result"]?["socket_path"] == .string(socketPath))

        #expect(lstat(link, &info) == 0 && info.st_mode & S_IFMT == S_IFLNK, "the old name is a symlink")
        #expect(try LineClient(path: link).send("ping") == "PONG", "a tool on the old path still connects")

        service.stop()
        #expect(access(socketPath, F_OK) != 0)
        #expect(lstat(link, &info) != 0, "stop removes its own link")
    }

    @Test func anExistingCanonicalStateDirectoryIsTightenedToOwnerOnly() throws {
        let home = "/tmp/cnch-\(UUID().uuidString.prefix(8).lowercased())"
        defer { try? FileManager.default.removeItem(atPath: home) }
        let state = "\(home)/.local/state/cmux"
        try FileManager.default.createDirectory(atPath: state, withIntermediateDirectories: true)
        try #require(chmod(state, 0o755) == 0)
        let (identity, _) = launch(home: home)

        let service = try ControlService.start(
            registry: ActionRegistry(catalog: []), settings: nil, launch: identity, environment: [:]
        )
        defer { service.stop() }

        var info = stat()
        #expect(lstat(state, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o700)
    }

    @Test func anExplicitSocketOverrideDoesNotChangeItsExistingParentMode() throws {
        let parent = "/tmp/cnco-\(UUID().uuidString.prefix(8).lowercased())"
        defer { try? FileManager.default.removeItem(atPath: parent) }
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        try #require(chmod(parent, 0o755) == 0)
        let identity = LaunchIdentity(
            bundleID: "com.cmuxterm.app.debug.override", tag: "override",
            socketPath: "\(parent)/app.sock"
        )

        let service = try ControlService.start(
            registry: ActionRegistry(catalog: []), settings: nil, launch: identity, environment: [:]
        )
        defer { service.stop() }

        var info = stat()
        #expect(lstat(parent, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o755)
    }

    @Test func aDeletedLinkComesBack() async throws {
        let home = "/tmp/cnch-\(UUID().uuidString.prefix(8).lowercased())"
        defer { try? FileManager.default.removeItem(atPath: home) }
        let (identity, tag) = launch(home: home)
        let service = try ControlService.start(registry: ActionRegistry(catalog: []), settings: nil, launch: identity, environment: [:])
        defer { service.stop() }
        let link = "/tmp/cmux-debug-\(tag).sock"
        #expect(unlink(link) == 0)
        let deadline = ContinuousClock.now + .seconds(5)
        var back = false
        while !back && ContinuousClock.now < deadline {
            back = (try? LineClient(path: link).send("ping")) == "PONG"
            if !back { try await Task.sleep(for: .milliseconds(20)) }
        }
        #expect(back, "the /tmp link is put back")
    }

    /// A listening socket bound at `path`; closing the descriptor leaves the file with no listener.
    func listener(at path: String) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(descriptor >= 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try #require(bound == 0 && listen(descriptor, 8) == 0)
        return descriptor
    }

    /// An app from before the move that crashed left its socket at the old name. Nothing
    /// listens there, so the link takes its place; else every tool on the old path is refused.
    @Test func aStaleSocketAtTheOldNameGivesWayToTheLink() throws {
        let home = "/tmp/cnch-\(UUID().uuidString.prefix(8).lowercased())"
        defer { try? FileManager.default.removeItem(atPath: home) }
        let (identity, tag) = launch(home: home)
        let link = "/tmp/cmux-debug-\(tag).sock"
        close(try listener(at: link))
        defer { unlink(link) }
        let service = try ControlService.start(registry: ActionRegistry(catalog: []), settings: nil, launch: identity, environment: [:])
        defer { service.stop() }
        var info = stat()
        #expect(lstat(link, &info) == 0 && info.st_mode & S_IFMT == S_IFLNK, "the stale socket is replaced by the link")
        #expect((try? LineClient(path: link).send("ping")) == "PONG", "a tool on the old path connects")
    }

    /// A socket something still listens on at the old name is never replaced.
    @Test func aLiveSocketAtTheOldNameIsLeftAlone() throws {
        let home = "/tmp/cnch-\(UUID().uuidString.prefix(8).lowercased())"
        defer { try? FileManager.default.removeItem(atPath: home) }
        let (identity, tag) = launch(home: home)
        let link = "/tmp/cmux-debug-\(tag).sock"
        let other = try listener(at: link)
        defer { close(other); unlink(link) }
        var info = stat()
        try #require(lstat(link, &info) == 0)
        let inode = info.st_ino
        let service = try ControlService.start(registry: ActionRegistry(catalog: []), settings: nil, launch: identity, environment: [:])
        defer { service.stop() }
        #expect(lstat(link, &info) == 0 && info.st_mode & S_IFMT == S_IFSOCK && info.st_ino == inode, "the live socket stays")
        #expect((try? LineClient(path: identity.socketPath).send("ping")) == "PONG", "the app still serves its own socket")
    }

    @Test func aPathTooLongForSunPathStaysAtItsOldName() throws {
        let home = "/tmp/cnch-" + String(repeating: "h", count: 80)
        let (identity, tag) = launch(home: home)
        #expect(identity.socketPath == "/tmp/cmux-debug-\(tag).sock", "a path sun_path cannot hold keeps the old name")
    }

    /// The rig's machine id (`CMUX_NEXT_MOBILE_MACHINE_ID`, read by
    /// `MobileHostLaunch`) survives the launch strip of inherited `CMUX*`
    /// variables; the host's own `CMUX_MOBILE_MACHINE_ID` would not.
    @Test func aRigsMachineIDSurvivesTheLaunchStrip() {
        let environment = ["CMUX_NEXT_MOBILE_MACHINE_ID": "0123456789abcdef0123456789abcdef",
                           "CMUX_MOBILE_MACHINE_ID": "0123456789abcdef0123456789abcdef"]
        let stripped = LaunchIdentity.inheritedKeys(processEnvironment: environment, bundledEnvironment: [:])
        #expect(!stripped.contains("CMUX_NEXT_MOBILE_MACHINE_ID"))
        #expect(stripped.contains("CMUX_MOBILE_MACHINE_ID"))
    }
}
