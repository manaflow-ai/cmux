// SPDX-License-Identifier: GPL-3.0-or-later
import CmuxRemoteWire
import Darwin
import Foundation
import Testing

/// The built `cmux-remote host` as a real process, driven over its sockets
/// the way the cmux-tui daemon and the cmux app drive it: the bootstrap pipe,
/// the supervisor hello and its refusals, status and the probe, the app
/// grant and the app socket's peer check, adoption by a second supervisor
/// connection after the first one ends, drain, and a launch with no daemon.
@Suite(.serialized) struct RemoteHostProcessTests {
    struct Host {
        let child: ChildProcess
        let layout: RemoteHostLayout
        let secret: Data
    }

    @Test(.timeLimit(.minutes(2))) func supervisorHelloStatusAdoptionAndDrain() throws {
        let host = try Self.start()
        defer { kill(host.child.pid, SIGKILL) }

        // A wrong secret, then a protocol range the host does not speak, are refused.
        let wrong = try Self.connect(host.layout.supervisorSocket)
        wrong.write(RemoteWire.line(["type": "hello", "secret": RemoteWire.hex(RemoteWire.makeSecret()), "min": 1, "max": 1]))
        #expect((wrong.readObject()?["error"] as? [String: Any])?["code"] as? String == "refused")
        let future = try Self.connect(host.layout.supervisorSocket)
        future.write(RemoteWire.line(["type": "hello", "secret": RemoteWire.hex(host.secret), "min": 99, "max": 99]))
        #expect((future.readObject()?["error"] as? [String: Any])?["code"] as? String == "protocol")

        // The daemon's hello: the version both speak and the host's status.
        let daemon = try Self.hello(host)
        let status = try Self.call(daemon, "status")
        #expect(status["pid"] as? Int == Int(host.child.pid))
        #expect(status["busy"] as? Bool == false)
        let refreshed = try Self.call(daemon, "refresh")
        let permissions = try #require(refreshed["permissions"] as? [String: Any], "a probe answer")
        #expect(permissions["accessibility"] is Bool && permissions["screen_recording"] is Bool)

        // The app grant names one process; the app socket admits only it, with the secret.
        let me = try #require(ProcessStamp.of(getpid()))
        let grant = try Self.call(daemon, "app_grant", ["app": me.fields])
        let appSecret = try #require(grant["secret"] as? String)
        let refused = try Self.connect(host.layout.appSocket)
        refused.write(RemoteWire.line(["type": "hello", "secret": RemoteWire.hex(RemoteWire.makeSecret())]))
        #expect((refused.readObject()?["error"] as? [String: Any])?["code"] as? String == "refused")
        let app = try Self.connect(host.layout.appSocket)
        app.write(RemoteWire.line(["type": "hello", "secret": appSecret]))
        app.write(RemoteWire.line(["id": 1, "channel": "screen-sharing"]))
        // Sharing is off: no worker runs.
        #expect((app.readObject()?["error"] as? [String: Any])?["code"] as? String == "worker_unavailable")
        app.close()

        // The daemon goes (a handoff): the host keeps serving and a new supervisor adopts it.
        daemon.close()
        let adopted = try Self.hello(host)
        #expect(try Self.call(adopted, "status")["pid"] as? Int == Int(host.child.pid))

        // Drain with no session: the host exits.
        _ = try? Self.call(adopted, "drain")
        var exitStatus: Int32 = 0
        #expect(waitpid(host.child.pid, &exitStatus, 0) == host.child.pid)
        #expect(exitStatus == 0)
    }

    @Test(.timeLimit(.minutes(1))) func aLaunchWithoutTheDaemonsBootstrapExitsAtOnce() throws {
        let built = try #require(Self.executable(), "the built cmux-remote")
        let directory = try Self.temporaryDirectory()
        let child = try ChildProcess.spawn(executable: built,
                                           arguments: ["host", "--layout-dir", directory + "/l", "--state-dir", directory + "/s", "--scope", "t"],
                                           environment: ["PATH": "/usr/bin:/bin"], logPath: directory + "/log")
        var status: Int32 = 0
        #expect(waitpid(child.pid, &status, 0) == child.pid)
        #expect(status == 0)
        #expect(!FileManager.default.fileExists(atPath: directory + "/l/s.sock"))
    }

    // MARK: Helpers

    static func start() throws -> Host {
        let built = try #require(Self.executable(), "the built cmux-remote")
        let directory = try temporaryDirectory()
        let layout = RemoteHostLayout(directory: directory + "/l")
        let secret = RemoteWire.makeSecret()
        var bootstrap: [Int32] = [-1, -1]
        #expect(pipe(&bootstrap) == 0)
        let line = RemoteWire.line(["supervisor_secret": RemoteWire.hex(secret), "daemon_build": "test",
                                    "computer_use": false, "screen_sharing": false, "headless": true])
        _ = LineChannel.writeAll(bootstrap[1], line)
        close(bootstrap[1])
        let child = try ChildProcess.spawn(executable: built,
                                           arguments: ["host", "--layout-dir", layout.directory, "--state-dir", directory + "/s", "--scope", "test"],
                                           environment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()],
                                           logPath: directory + "/host.log", inherit: [(bootstrap[0], 3)])
        close(bootstrap[0])
        close(child.stdin)
        let ready = LineChannel(read: child.stdout, write: child.stdout).readLine()
        #expect(ready == Data("ready".utf8))
        return Host(child: child, layout: layout, secret: secret)
    }

    static func connect(_ path: String) throws -> LineChannel {
        LineChannel(socket: try LocalSocket.connect(path))
    }

    static func hello(_ host: Host) throws -> LineChannel {
        let channel = try connect(host.layout.supervisorSocket)
        channel.write(RemoteWire.line(["type": "hello", "secret": RemoteWire.hex(host.secret), "min": 1, "max": 1]))
        let hello = try #require(channel.readObject())
        #expect(hello["type"] as? String == "hello")
        #expect(hello["protocol"] as? Int == 1)
        return channel
    }

    /// One request; events before the answer are skipped.
    static func call(_ channel: LineChannel, _ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
        let id = Int.random(in: 1 ... 1_000_000)
        channel.write(RemoteWire.line(["id": id, "method": method, "params": params]))
        while let answer = channel.readObject() {
            guard answer["id"] as? Int == id else { continue }
            #expect(answer["ok"] as? Bool == true, "\(method): \(answer)")
            return answer["result"] as? [String: Any] ?? [:]
        }
        throw CocoaError(.fileReadUnknown)
    }

    static func temporaryDirectory() throws -> String {
        // Short: socket paths must fit sockaddr_un.
        let path = "/tmp/crh-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return path
    }

    /// The built `cmux-remote`: beside a loaded .xctest bundle, else in this package's .build.
    static func executable() -> String? {
        var candidates = (Bundle.allBundles + Bundle.allFrameworks).map(\.bundleURL)
            .filter { $0.pathExtension == "xctest" }
            .map { $0.deletingLastPathComponent().appending(path: "cmux-remote").path }
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let build = package.appending(path: ".build")
        candidates.append(build.appending(path: "debug/cmux-remote").path)
        for triple in (try? FileManager.default.contentsOfDirectory(atPath: build.path)) ?? [] {
            candidates.append(build.appending(path: "\(triple)/debug/cmux-remote").path)
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
