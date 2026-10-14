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

    @Test func aPathTooLongForSunPathStaysAtItsOldName() throws {
        let home = "/tmp/cnch-" + String(repeating: "h", count: 80)
        let (identity, tag) = launch(home: home)
        #expect(identity.socketPath == "/tmp/cmux-debug-\(tag).sock", "a path sun_path cannot hold keeps the old name")
    }
}
