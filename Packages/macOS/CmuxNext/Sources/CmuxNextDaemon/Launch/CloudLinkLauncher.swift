public import CmuxNextCompat
public import Foundation
import Darwin
import os

/// The private, link-only credential carrier. It is intentionally not an app
/// provider route: the accepted peer is the exact supervised cmux-tui process
/// (pid, process start stamp and executable), and each connection carries one
/// bounded request only.
private final class CloudLinkCredentialServer: @unchecked Sendable {
    private struct Stamp: Equatable { let pid: pid_t; let startSeconds: UInt64; let startMicros: UInt64 }
    private let path: String
    private let executable: String
    private let relay: CloudCredentialRelay
    private let lock = NSLock()
    private var expected: Stamp?
    private var listener: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "cmux.cloud.link-credential", qos: .utility)
    private let maxLine = 64 * 1024

    init(path: String, executable: URL, relay: CloudCredentialRelay) {
        self.path = path
        self.executable = executable.resolvingSymlinksInPath().standardizedFileURL.path
        self.relay = relay
    }

    func start() {
        queue.async { [weak self] in self?.bind() }
    }

    func expect(pid: Int32?) {
        let stamp = pid.flatMap { Self.stamp(pid_t($0)) }
        lock.lock(); expected = stamp; lock.unlock()
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            let fd = self.listener
            self.listener = -1
            let hadSource = self.source != nil
            self.source?.cancel(); self.source = nil
            if !hadSource, fd >= 0 { Darwin.close(fd) }
            unlink(self.path)
            self.lock.lock(); self.expected = nil; self.lock.unlock()
        }
    }

    private func bind() {
        guard listener < 0 else { return }
        let parent = (path as NSString).deletingLastPathComponent
        if !FileManager.default.fileExists(atPath: parent) {
            try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
        }
        var directory = stat()
        guard lstat(parent, &directory) == 0, directory.st_uid == getuid(), directory.st_mode & S_IFMT == S_IFDIR,
              directory.st_mode & 0o077 == 0 else { return }
        var existing = stat()
        if lstat(path, &existing) == 0 {
            guard existing.st_uid == getuid(), existing.st_mode & S_IFMT == S_IFSOCK else { return }
            let probe = socket(AF_UNIX, SOCK_STREAM, 0)
            if probe >= 0 {
                var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
                let bytes = Array(path.utf8)
                guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { Darwin.close(probe); return }
                withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
                let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
                Darwin.close(probe)
                if connected == 0 { return }
            }
            unlink(path)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { Darwin.close(fd); return }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0, Darwin.listen(fd, 8) == 0 else { Darwin.close(fd); unlink(path); return }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        _ = chmod(path, 0o600)
        listener = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.accept() }
        source.setCancelHandler { Darwin.close(fd) }
        self.source = source
        source.resume()
    }

    private func accept() {
        while listener >= 0 {
            let fd = Darwin.accept(listener, nil, nil)
            guard fd >= 0 else { return }
            let allowed = authorized(fd)
            if !allowed { Darwin.close(fd); continue }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { Darwin.close(fd); return }
                Task { await self.serve(fd) }
            }
        }
    }

    private func authorized(_ fd: Int32) -> Bool {
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { return false }
        var pid: pid_t = 0, length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0 else { return false }
        guard let current = Self.stamp(pid), let executable = Self.path(pid) else { return false }
        lock.lock(); defer { lock.unlock() }
        return expected == current && executable == self.executable
    }

    private func serve(_ fd: Int32) async {
        defer { Darwin.close(fd) }
        var data = Data(); var byte: UInt8 = 0
        while data.count <= maxLine {
            let count = Darwin.read(fd, &byte, 1)
            guard count == 1 else { return }
            if byte == 10 { break }
            data.append(byte)
        }
        guard data.count <= maxLine, let request = try? JSONDecoder().decode(Request.self, from: data) else { return }
        let reply = await Self.answer(request, relay: relay)
        guard let output = try? JSONEncoder().encode(reply) else { return }
        _ = output.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, output.count) }
        var newline: UInt8 = 10; _ = Darwin.write(fd, &newline, 1)
    }

    private struct Request: Decodable {
        let op: String; let host: String; let services: [String]?
        private enum CodingKeys: String, CodingKey, CaseIterable { case op, host, services }
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let allowed = Set(CodingKeys.allCases.map(\.stringValue))
            guard Set(container.allKeys.map(\.stringValue)).subtracting(allowed).isEmpty else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown link request field"))
            }
            op = try container.decode(String.self, forKey: .op)
            host = try container.decode(String.self, forKey: .host)
            services = try container.decodeIfPresent([String].self, forKey: .services)
        }
    }
    private static func answer(_ request: Request, relay: CloudCredentialRelay) async -> JSONValue {
        guard request.host.utf8.count == 25, request.host.hasPrefix("host_"),
              request.host.utf8.dropFirst(5).allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 122) }) else {
            return .object(["ok": .bool(false), "error": .object(["code": .string("validation.invalid"), "message": .string("invalid host")])])
        }
        let answer: CloudCredentialRelay.Answer
        switch request.op {
        case "connect_info":
            guard request.services == nil else { return .object(["ok": .bool(false), "error": .object(["code": .string("validation.invalid"), "message": .string("connect_info does not take services")])]) }
            answer = await relay.linkConnectInfo(host: request.host)
        case "link_token":
            guard let services = request.services, !services.isEmpty, Set(services).isSubset(of: ["daemon", "ssh"]), Set(services).count == services.count else { return .object(["ok": .bool(false), "error": .object(["code": .string("validation.invalid"), "message": .string("invalid services")])]) }
            answer = await relay.linkToken(host: request.host, services: services)
        default:
            return .object(["ok": .bool(false), "error": .object(["code": .string("operation.unsupported"), "message": .string("unsupported link operation")])])
        }
        if answer.ok { return .object(["ok": .bool(true), "value": answer.body["value"] ?? .null]) }
        return .object(["ok": .bool(false), "error": answer.body])
    }

    private static func path(_ pid: pid_t) -> String? {
        var bytes = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let count = proc_pidpath(pid, &bytes, UInt32(bytes.count))
        return count > 0 ? URL(fileURLWithPath: String(decoding: bytes.prefix(Int(count)).map { UInt8(bitPattern: $0) }, as: UTF8.self))
            .resolvingSymlinksInPath().standardizedFileURL.path : nil
    }

    private static func stamp(_ pid: pid_t) -> Stamp? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Stamp(pid: pid, startSeconds: info.pbi_start_tvsec, startMicros: info.pbi_start_tvusec)
    }
}

/// Runs this Mac's `cmux link` for the Cloud app server (cx-rtipa S3): the
/// app starts it on demand with `cmux-tui link ensure` (the same model as
/// the session daemon's `server ensure`: a detached process that survives
/// the app), tells the daemon with `apps-link-changed` so the Cloud server
/// sees the new link at once, and stops it at sign-out (`link stop`, which
/// signals only the registered pid). Nothing else starts or stops the link.
///
/// Isolation: a tagged DEV build (any build with its own names) gives the link its daemon's state directory
/// (`CMUX_TUI_STATE_DIR`, as ``DaemonLauncher`` does for the daemon), so its
/// registration, socket and key never meet another build's link; it binds
/// any free UDP port (`--port 0`) and reads no `~/.config/cmux/server.json`
/// (the tag's own `server.json`, normally absent).
public nonisolated struct CloudLinkLauncher: Sendable {
    /// What `link ensure` answered.
    public struct Ensured: Decodable, Equatable, Sendable {
        /// `running`, `started` or `restarted`.
        public var status: String
        public var pid: Int32?
        public var socket: String?
    }

    public enum Failure: Error, Equatable {
        /// The command failed; `detail` is its last stderr line.
        case failed(String)
        case badAnswer
    }

    let binary: URL
    /// The daemon state root (`CMUX_TUI_STATE_DIR`); nil = cmux-tui's default.
    let stateRoot: URL?
    /// `TMPDIR` for the link (``DaemonLauncher/userTemporaryDirectory()``),
    /// so the socket does not move with the app's launch environment.
    let runtimeBase: URL
    let tagged: Bool
    private let credentialServer: CloudLinkCredentialServer?
    private let clock: any Clock<Duration>

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "cloud.link")
    private static let timeout: Duration = .seconds(30)

    public init(binary: URL, stateRoot: URL?, runtimeBase: URL = DaemonLauncher.userTemporaryDirectory(), tagged: Bool,
         relay: CloudCredentialRelay? = nil, clock: any Clock<Duration> = ContinuousClock()) {
        self.binary = binary
        self.stateRoot = stateRoot
        self.runtimeBase = runtimeBase
        self.tagged = tagged
        if let relay, let stateRoot {
            self.credentialServer = CloudLinkCredentialServer(path: stateRoot.appendingPathComponent("link-credential.sock").path, executable: binary, relay: relay)
        } else {
            self.credentialServer = nil
        }
        self.clock = clock
    }

    /// This app's launcher: only the app bundle's own `bin/cmux-tui` (never
    /// a `CMUX_NEXT_TUI_BIN` override) and its build's state: a kept tag's
    /// (`tags/<tag>/tui`), names of the build key (`builds/<key>/tui`, as the
    /// daemon's, per-build isolation S3), else cmux-tui's default root
    /// (release, the untagged channels). A DEBUG build without its own state
    /// gets no link: it would share the release app's state directory.
    public static func forApp(bundle: Bundle = .main, build: BuildIdentity, relay: CloudCredentialRelay? = nil) -> CloudLinkLauncher? {
        guard let resources = bundle.resourceURL else { return nil }
        let binary = resources.appendingPathComponent("bin/cmux-tui")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { return nil }
        let own = build.keepsAppNames
            ? build.tag.map { DaemonLauncher.tagStateDirectory(tag: $0) }
            : DaemonLauncher.appNames(build: build).stateDirectory
        #if DEBUG
        guard own != nil else { return nil }
        #endif
        let stateRoot = own ?? defaultStateRoot()
        guard let stateRoot else { return nil }
        return CloudLinkLauncher(binary: binary, stateRoot: stateRoot, tagged: own != nil, relay: relay)
    }

    /// cmux-tui's default daemon state root on macOS
    /// (`~/Library/Application Support/cmux-tui/sessions`), named explicitly
    /// so `--state-dir` is always given.
    static func defaultStateRoot() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("cmux-tui/sessions", isDirectory: true)
    }

    /// The link's state directory.
    var stateDirectory: URL? { stateRoot?.appendingPathComponent("link", isDirectory: true) }

    /// The private credential socket passed to `cmux-tui link`; it carries no
    /// token and is only useful while this app's relay is serving.
    var credentialSocket: URL? { stateRoot?.appendingPathComponent("link-credential.sock") }

    /// The `link ensure` command line for `install` (pure). `--handoff`
    /// goes only with an explicit `--state-dir`.
    func ensureArguments(install: String) -> [String] {
        guard let stateDirectory else { return ["link", "ensure", "--install", install] }
        var arguments = ["link", "ensure", "--install", install, "--handoff", "--state-dir", stateDirectory.path]
        if let credentialSocket { arguments += ["--credential-socket", credentialSocket.path] }
        if tagged, let stateRoot {
            arguments += ["--port", "0", "--server-config", stateRoot.appendingPathComponent("server.json").path]
        }
        return arguments
    }

    func stopArguments() -> [String] {
        ["link", "stop"] + (stateDirectory.map { ["--state-dir", $0.path] } ?? [])
    }

    /// `link archive`: after a sign-out, the signed-out install's key and
    /// peers go into its archive and the config goes, so no later ensure
    /// without `--install` starts the link as that account.
    func archiveArguments() -> [String] {
        ["link", "archive"] + (stateDirectory.map { ["--state-dir", $0.path] } ?? [])
    }

    /// The variables the link may get from the app's environment; nothing
    /// else (no `CMUX_NEXT_*`, no `DYLD_*`, no credentials) reaches it.
    static let inheritedKeys = ["HOME", "USER", "LOGNAME", "PATH", "LANG", "LC_ALL", "SHELL"]

    /// The link's environment: the allow-listed variables of `base`, the
    /// state root and the fixed runtime base.
    func environment(_ base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = base.filter { Self.inheritedKeys.contains($0.key) }
        if let stateRoot { environment["CMUX_TUI_STATE_DIR"] = stateRoot.path }
        environment["TMPDIR"] = runtimeBase.path
        return environment
    }

    /// Starts the link unless one of this build runs. Off the main actor.
    @concurrent public func ensure(install: String) async throws -> Ensured {
        credentialServer?.start()
        let result = try await run(ensureArguments(install: install))
        guard let ensured = try? JSONDecoder().decode(Ensured.self, from: Self.lastLine(result.stdout)) else {
            throw Failure.badAnswer
        }
        credentialServer?.expect(pid: ensured.pid)
        if ensured.status != "running" {
            Self.logger.info("cloud link \(ensured.status, privacy: .public) pid \(ensured.pid ?? 0)")
        }
        return ensured
    }

    /// Stops the link (sign-out, session end, policy). A failure is logged
    /// with the install id only (the old config then stays).
    @concurrent public func stop(install: String? = nil) async {
        credentialServer?.stop()
        do {
            _ = try await run(stopArguments())
        } catch {
            Self.logger.error("cloud link stop failed for install \(install ?? "unknown", privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// Archives the signed-out install's key and peers (`link archive`). A
    /// failure is logged only.
    @concurrent public func archive(install: String? = nil) async {
        do {
            _ = try await run(archiveArguments())
        } catch {
            Self.logger.error("cloud link archive failed for install \(install ?? "unknown", privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    private func run(_ arguments: [String]) async throws -> ProcessResult {
        let result = try await ProcessRunner.run(executable: binary, arguments: arguments, environment: environment(),
                                                 timeout: Self.timeout, clock: clock)
        guard result.status == 0 else {
            let detail = String(decoding: Self.lastLine(result.stderr), as: UTF8.self)
            throw Failure.failed(detail)
        }
        return result
    }

    static func lastLine(_ data: Data) -> Data {
        let text = String(decoding: data, as: UTF8.self)
        let line = text.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        return Data(line.utf8)
    }
}
