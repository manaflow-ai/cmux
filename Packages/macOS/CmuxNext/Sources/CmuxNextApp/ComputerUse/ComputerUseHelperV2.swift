// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import os
import Security

private let helperV2Logger = Logger(subsystem: "com.cmuxterm.app.next", category: "computer-use-v2")

/// The cmux Computer Use helper v2 (`computerUse.driver = "upstream"`).
///
/// The helper app ("cmux Computer Use (dev).app" in DEV builds, bundle id
/// com.cmuxterm.cua.dev) runs upstream Cua Driver in process. This app
/// starts it with responsibility disclaimed (`DisclaimedHelperSpawner`), so
/// macOS checks Accessibility and Screen Recording against the helper and
/// never against cmux. Its stdin is our control pipe: we send the socket
/// path, the per-launch secret and the trusted acpmux cdhash there, and
/// EOF (stop, quit or crash of this app) stops the helper.
///
/// The helper socket admits only `acpmux cua-mcp` bridges that descend from
/// an acpmux daemon this app registered (`registerAcpmuxDaemon`). acpmux
/// finds the socket and secret in `endpoint.json` in the private directory
/// named by `endpointDirectoryKey`, which every acpmux daemon this app
/// spawns gets in its environment. Same-uid processes can read that file;
/// the secret is defense in depth, the kernel identity checks are the boundary.
@MainActor
final class ComputerUseHelperV2 {
    enum State: Equatable {
        case off
        /// On, but the helper is missing, did not start, or responsibility
        /// could not be disclaimed.
        case unavailable(String)
        case running(pid_t)
    }

    static let helperAppName = "cmux Computer Use (dev).app"
    static let helperBundleID = "com.cmuxterm.cua.dev"
    static let helperExecutableName = "cmux-cua-helper"
    /// The variable that names the endpoint directory for acpmux.
    nonisolated static let endpointDirectoryKey = "CMUX_NEXT_CUA_V2_DIR"
    nonisolated static let endpointFileName = "endpoint.json"
    nonisolated static let socketFileName = "h.sock"

    private(set) var state: State = .off
    let directory: String
    private let helperApp: @Sendable () -> URL?
    /// This app's acpmux (executable and daemon socket), set by the agent
    /// pane source once it resolves acpmux.
    var acpmux: @Sendable () -> (executable: URL, socketPath: String)?
    private let spawner: any ComputerUseHelperV2Spawning
    private let clock: any Clock<Duration>
    private let readyTimeout: Duration
    private let exitGrace: Duration
    private var child: ComputerUseHelperV2Child?
    private var generation = 0

    init(directory: String = ComputerUseHelperV2.defaultDirectory(),
         helperApp: @escaping @Sendable () -> URL? = { ComputerUseHelperV2.embeddedHelperApp() },
         acpmux: @escaping @Sendable () -> (executable: URL, socketPath: String)? = { nil },
         spawner: any ComputerUseHelperV2Spawning = DisclaimedHelperSpawner(),
         clock: any Clock<Duration> = ContinuousClock(),
         readyTimeout: Duration = .seconds(10),
         exitGrace: Duration = .seconds(2)) {
        self.directory = directory
        self.helperApp = helperApp
        self.acpmux = acpmux
        self.spawner = spawner
        self.clock = clock
        self.readyTimeout = readyTimeout
        self.exitGrace = exitGrace
    }

    var socketPath: String { directory + "/" + Self.socketFileName }
    var endpointPath: String { directory + "/" + Self.endpointFileName }

    /// What every acpmux daemon this app spawns gets: the endpoint directory
    /// (constant for this app build, so a daemon that outlives a helper
    /// restart still finds the current endpoint).
    nonisolated static func childEnvironment(directory: String) -> [String: String] {
        [endpointDirectoryKey: directory]
    }

    /// The helper's whole environment (nothing is inherited from this app,
    /// whose environment carries cmux tokens). The helper forces the same
    /// Cua Driver values itself before the driver loads.
    nonisolated static func environment(home: String = NSHomeDirectory(),
                                        temporaryDirectory: String = ComputerUseHelperDaemon.userTemporaryDirectory(),
                                        user: String = NSUserName()) -> [String: String] {
        // RED STUB (commit 1): the Cua Driver values are missing.
        if true { return ["HOME": home] }
        return [
            "CUA_DRIVER_RS_TELEMETRY_ENABLED": "0",
            "CUA_TELEMETRY_ENABLED": "false",
            "CUA_DRIVER_RS_UPDATE_CHECK": "false",
            // Upstream waits up to 1000 ms after each input action for a
            // window change, even when the target redraws; 100 ms keeps a 2x
            // margin over the measured 50 ms (134 ms clicks) for a new window
            // or sheet to appear.
            "CUA_DRIVER_WINDOW_CHANGE_TIMEOUT_MS": "100",
            "CUA_DRIVER_HOST_BUNDLE_ID": helperBundleID,
            "HOME": home,
            "TMPDIR": temporaryDirectory,
            "USER": user,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ]
    }

    /// `<this user's temp dir>/cmux-cua-v2/<scope>`: per user, 0700, one
    /// per app build (bundle id), short enough for a socket address.
    nonisolated static func defaultDirectory(bundleID: String = Bundle.main.bundleIdentifier ?? "com.cmuxterm.app") -> String {
        "\(ComputerUseHelperDaemon.userTemporaryDirectory())cmux-cua-v2/\(ComputerUseHelperDaemon.scope(bundleID))"
    }

    /// DEV builds embed the dev helper at Contents/Library (scripts/cmux-next/embed-cua-helper-dev.sh).
    nonisolated static func embeddedHelperApp(bundle: Bundle = .main) -> URL? {
        let url = bundle.bundleURL.appending(path: "Contents/Library/\(helperAppName)", directoryHint: .isDirectory)
        return FileManager.default.fileExists(atPath: url.appending(path: "Contents/MacOS/\(helperExecutableName)").path) ? url : nil
    }

    /// Computer Use on with the upstream driver: start the helper (once); otherwise stop it.
    func apply(enabled: Bool) async {
        generation &+= 1
        let current = generation
        guard enabled else { return await stop() }
        if case .running = state { return }
        guard let app = helperApp() else { return unavailable("the cmux Computer Use (dev) helper is not in this build") }
        guard ComputerUseHelperDaemon.makePrivateDirectory((directory as NSString).deletingLastPathComponent),
              ComputerUseHelperDaemon.makePrivateDirectory(directory) else {
            return unavailable("\(directory) is not a private directory of this user")
        }
        unlink(endpointPath)
        let executable = app.appending(path: "Contents/MacOS/\(Self.helperExecutableName)")
        let spawned: ComputerUseHelperV2Child
        do {
            spawned = try spawner.spawn(executable: executable, environment: Self.environment(),
                                        logPath: directory + "/helper.log")
        } catch {
            return unavailable("the helper did not start: \(error)")
        }
        let secret = Self.makeSecret()
        let acpmux = self.acpmux()
        let hashes = acpmux.flatMap { Self.cdhash($0.executable) }.map { [Self.hex($0)] } ?? []
        await spawned.send(Self.line(["type": "configure", "socket": socketPath, "secret": Self.hex(secret),
                                "acpmux_cdhashes": hashes]))
        let ready = await Self.firstLine(of: spawned, type: "ready", within: readyTimeout, clock: clock)
        guard current == generation else {
            spawned.closeInput()
            spawner.terminate(spawned.pid)
            return
        }
        guard ready?["socket"] as? String == socketPath else {
            spawned.closeInput()
            spawner.terminate(spawned.pid)
            return unavailable("the helper did not report ready")
        }
        child = spawned
        state = .running(spawned.pid)
        guard await Self.writeEndpoint(path: endpointPath, socket: socketPath, secret: secret) else {
            await stop()
            return unavailable("cannot write \(endpointPath)")
        }
        helperV2Logger.notice("cmux Computer Use helper v2 started pid=\(spawned.pid, privacy: .public)")
        // An acpmux daemon that already runs (it outlives the app) is registered now.
        if let acpmux { await registerAcpmuxDaemon(acpmuxSocket: acpmux.socketPath) }
    }

    /// Registers the acpmux daemon listening on `acpmuxSocket`, after checking
    /// it runs this app's acpmux executable. Its descendants (agent MCP
    /// bridges) may then use the helper.
    func registerAcpmuxDaemon(acpmuxSocket: String) async {
        guard let child, let executable = acpmux()?.executable,
              let stamp = await Self.daemonStamp(socketPath: acpmuxSocket, executable: executable) else { return }
        await child.send(Self.line(["type": "register_acpmux", "pid": Int(stamp.pid),
                              "start_sec": Int(stamp.startSeconds), "start_usec": Int(stamp.startMicroseconds)]))
    }

    /// Stops the helper: close its stdin (it exits on EOF), then SIGTERM this
    /// exact pid if it is still alive after `exitGrace`.
    func stop() async {
        unlink(endpointPath)
        guard let child else {
            state = .off
            return
        }
        self.child = nil
        state = .off
        // RED STUB (commit 1): stdin stays open.
        let spawner = self.spawner
        // wakeup-allow: one bounded grace before SIGTERM when the helper is stopped.
        try? await clock.sleep(for: exitGrace)
        if kill(child.pid, 0) == 0 { spawner.terminate(child.pid) }
    }

    /// App quit: close the helper's stdin now (it exits on EOF; the kernel
    /// closes the pipe anyway if this app dies).
    func terminateForQuit() {
        generation &+= 1
        unlink(endpointPath)
        child?.closeInput()
        child = nil
        state = .off
    }

    private func unavailable(_ reason: String) {
        helperV2Logger.error("cmux Computer Use helper v2 unavailable: \(reason, privacy: .public)")
        state = .unavailable(reason)
    }

    // MARK: - Helpers

    nonisolated static func line(_ fields: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])) ?? Data()
        data.append(0x0A)
        return data
    }

    nonisolated static func makeSecret() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }

    nonisolated static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    /// The cdhash of a signed executable on disk.
    nonisolated static func cdhash(_ url: URL) -> Data? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, [], &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoUnique as String] as? Data
    }

    /// endpoint.json for acpmux: 0600, written to a temporary name and renamed.
    @concurrent nonisolated static func writeEndpoint(path: String, socket: String, secret: Data) async -> Bool {
        let body = line(["protocol": 1, "socket": socket, "secret": hex(secret)])
        let temporary = path + ".tmp"
        unlink(temporary)
        let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return false }
        // concurrency-allow: @concurrent, never on the main actor; one small local file.
        let written = body.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        close(descriptor)
        guard written == body.count, rename(temporary, path) == 0 else {
            unlink(temporary)
            return false
        }
        return true
    }

    /// pid + start time of the process listening on `socketPath`, when it
    /// runs `executable`.
    @concurrent nonisolated static func daemonStamp(socketPath: String, executable: URL) async -> (pid: pid_t, startSeconds: UInt64, startMicroseconds: UInt64)? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        guard socketPath.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: socketPath.utf8)
            buffer[socketPath.utf8.count] = 0
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                // concurrency-allow: @concurrent, never on the main actor; a local Unix socket connect.
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0, pid > 1 else { return nil }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0,
              URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath().path
                == executable.resolvingSymlinksInPath().path else { return nil }
        var info = proc_bsdinfo()
        let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, infoSize) == infoSize else { return nil }
        return (pid, info.pbi_start_tvsec, info.pbi_start_tvusec)
    }

    /// The first stdout line of `type`, or nil after `within`.
    nonisolated static func firstLine(of child: ComputerUseHelperV2Child, type: String, within: Duration,
                                      clock: any Clock<Duration>) async -> [String: Any]? {
        await withTaskGroup(of: [String: Any]?.self) { group in
            group.addTask {
                for await line in child.lines {
                    if let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                       object["type"] as? String == type { return object }
                }
                return nil
            }
            group.addTask {
                // wakeup-allow: one bounded ready deadline per helper start, cancelled as soon as the helper answers.
                try? await clock.sleep(for: within)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
