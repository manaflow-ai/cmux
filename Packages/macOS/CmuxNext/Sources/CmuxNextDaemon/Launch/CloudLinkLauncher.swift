public import CmuxNextCompat
public import Foundation
import Darwin
import CmuxNextWakeups
import os

/// The private, link-only credential carrier. It is intentionally not an app
/// provider route: the accepted peer is the exact supervised cmux-tui process
/// (pid, process start stamp and executable), and each connection carries one
/// bounded request only.
private final class CloudLinkCredentialServer: Sendable {
    private struct Stamp: Equatable { let pid: pid_t; let startSeconds: UInt64; let startMicros: UInt64 }
    private struct Expected: Equatable { let stamp: Stamp; let install: String }
    enum StartError: Error { case unavailable(String) }
    private let path: String
    private let executable: String
    private let relay: CloudCredentialRelay
    private struct State {
        var expected: Expected?
        var listener: Int32 = -1
        var source: (any DispatchSourceRead)?
        var ownsPath = false
        var activeReaders = 0
        var generation: UInt64 = 0
        var tasks: [UUID: Task<Void, Never>] = [:]
    }
    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "cmux.cloud.link-credential", qos: .utility)
    private let maxLine = 64 * 1024

    init(path: String, executable: URL, relay: CloudCredentialRelay) {
        self.path = path
        self.executable = executable.resolvingSymlinksInPath().standardizedFileURL.path
        self.relay = relay
    }

    deinit {
        state.withLock { state in
            state.source?.cancel()
            if state.ownsPath { unlink(path) }
            for task in state.tasks.values { task.cancel() }
        }
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [weak self] in
                guard let self else { continuation.resume(throwing: StartError.unavailable("credential server deallocated")); return }
                do { try self.bind(); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    func expect(pid: Int32?, install: String) {
        let stamp = pid.flatMap { Self.stamp($0) }
        state.withLock { $0.expected = stamp.map { Expected(stamp: $0, install: install) } }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.state.withLock { state in
                state.listener = -1
                state.source?.cancel()
                state.source = nil
                if state.ownsPath { unlink(self.path) }
                state.ownsPath = false
                state.expected = nil
                state.generation &+= 1
                for task in state.tasks.values { task.cancel() }
                state.tasks.removeAll()
            }
        }
    }

    private func bind() throws {
        guard state.withLock({ $0.listener < 0 }) else { return }
        let parent = (path as NSString).deletingLastPathComponent
        if !FileManager.checked.fileExists(atPath: parent) {
            do { try FileManager.checked.createDirectory(atPath: parent, withIntermediateDirectories: true,
                                                         attributes: [.posixPermissions: 0o700]) }
            catch { throw StartError.unavailable("cannot create credential socket directory") }
        }
        var directory = stat()
        guard lstat(parent, &directory) == 0, directory.st_uid == getuid(), directory.st_mode & S_IFMT == S_IFDIR,
              directory.st_mode & 0o077 == 0 else { throw StartError.unavailable("credential socket directory is not private") }
        var existing = stat()
        if lstat(path, &existing) == 0 {
            guard existing.st_uid == getuid(), existing.st_mode & S_IFMT == S_IFSOCK else { throw StartError.unavailable("credential socket path is not a private socket") }
            let probe = socket(AF_UNIX, SOCK_STREAM, 0)
            if probe >= 0 {
                var address = sockaddr_un(); address.sun_family = sa_family_t(clamping: AF_UNIX)
                let bytes = Array(path.utf8)
                guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { Darwin.close(probe); throw StartError.unavailable("credential socket path is too long") }
                withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
                let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(probe, $0, socklen_t(clamping: MemoryLayout<sockaddr_un>.size)) } }
                Darwin.close(probe)
                if connected == 0 { throw StartError.unavailable("credential socket is already in use") }
                // Never remove a socket we cannot prove belongs to this
                // process. Each launcher instance has a unique endpoint.
                throw StartError.unavailable("credential socket path is unavailable")
            }
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StartError.unavailable("cannot create credential socket") }
        var address = sockaddr_un(); address.sun_family = sa_family_t(clamping: AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { Darwin.close(fd); throw StartError.unavailable("credential socket path is too long") }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(clamping: MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0, Darwin.listen(fd, 8) == 0 else { Darwin.close(fd); throw StartError.unavailable("cannot bind credential socket") }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        _ = chmod(path, 0o600)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.accept() }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        state.withLock { $0.listener = fd; $0.ownsPath = true; $0.source = source }
    }

    private func accept() {
        while case let listener = state.withLock({ $0.listener }), listener >= 0 {
            let fd = Darwin.accept(listener, nil, nil)
            guard fd >= 0 else { return }
            guard let install = authorized(fd) else { Darwin.close(fd); continue }
            var noSigPipe: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(clamping: MemoryLayout<Int32>.size))
            var sendTimeout = timeval(tv_sec: 5, tv_usec: 0)
            _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(clamping: MemoryLayout<timeval>.size))
            let generation = state.withLock { state -> UInt64? in
                guard state.activeReaders < 32 else { return nil }
                state.activeReaders += 1
                return state.generation
            }
            guard let generation else { Darwin.close(fd); continue }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { Darwin.close(fd); return }
                self.serve(fd, expectedInstall: install, generation: generation)
            }
        }
    }

    private func authorized(_ fd: Int32) -> String? {
        guard let peer = UnixSocketPeer(descriptor: fd), peer.uid == getuid(),
              let current = Self.stamp(peer.pid), peer.executablePath == executable else { return nil }
        return state.withLock { state in
            guard let expected = state.expected, expected.stamp == current else { return nil }
            return expected.install
        }
    }

    private func finish(_ fd: Int32, id: UUID) {
        state.withLock { state in
            state.tasks.removeValue(forKey: id)
            state.activeReaders -= 1
        }
        Darwin.close(fd)
    }

    private func serve(_ fd: Int32, expectedInstall: String, generation: UInt64) {
        let id = UUID()
        var data = Data(); var byte: UInt8 = 0
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        while data.count <= maxLine {
            var descriptor = pollfd(fd: fd, events: Int16(clamping: POLLIN), revents: 0)
            let now = DispatchTime.now().uptimeNanoseconds
            let remaining = now < deadline ? Int32(clamping: (deadline - now) / 1_000_000) : 0
            let ready = poll(&descriptor, 1, remaining)
            guard ready > 0 else { finish(fd, id: id); return }
            let count = blockingRead(fd, &byte, 1)
            if count < 0 && errno == EINTR { continue }
            guard count == 1 else { finish(fd, id: id); return }
            if byte == 10 { break }
            data.append(byte)
        }
        guard data.count <= maxLine, let request = try? JSONDecoder().decode(Request.self, from: data) else { finish(fd, id: id); return }
        let started = state.withLock { state -> Bool in
            guard state.generation == generation, state.expected?.install == expectedInstall else { return false }
            state.tasks[id] = Task { [weak self, relay] in
                guard let self else { Darwin.close(fd); return }
                defer { self.finish(fd, id: id) }
                guard !Task.isCancelled, await relay.installID() == expectedInstall else { return }
                let reply = await Self.answer(request, relay: relay, expectedInstall: expectedInstall)
                guard !Task.isCancelled, self.state.withLock({ $0.generation == generation }),
                      let output = try? JSONEncoder().encode(reply), output.count < self.maxLine else { return }
                // Socket writes belong on the bounded utility lane, never a cooperative executor.
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    DispatchQueue.global(qos: .utility).async {
                        defer { continuation.resume() }
                        var bytes = output; bytes.append(10)
                        bytes.withUnsafeBytes { raw in
                            guard let base = raw.baseAddress else { return }
                            var sent = 0
                            while sent < bytes.count {
                                let n = blockingSend(fd, base.advanced(by: sent), bytes.count - sent, 0)
                                if n > 0 { sent += n } else if n < 0 && errno == EINTR { continue } else { break }
                            }
                        }
                    }
                }
            }
            return true
        }
        if !started { finish(fd, id: id) }
    }

    private struct Request: Decodable {
        let op: String; let host: String; let services: [String]?
        private enum CodingKeys: String, CodingKey, CaseIterable { case op, host, services }
        init(from decoder: any Decoder) throws {
            struct AnyKey: CodingKey { let stringValue: String; let intValue: Int?; init?(stringValue: String) { self.stringValue = stringValue; self.intValue = nil }; init?(intValue: Int) { return nil } }
            let container = try decoder.container(keyedBy: AnyKey.self)
            let allowed = Set(CodingKeys.allCases.map(\.stringValue))
            guard Set(container.allKeys.map(\.stringValue)).subtracting(allowed).isEmpty else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown link request field"))
            }
            guard let opKey = container.allKeys.first(where: { $0.stringValue == "op" }),
                  let hostKey = container.allKeys.first(where: { $0.stringValue == "host" }) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "missing link request field"))
            }
            op = try container.decode(String.self, forKey: opKey)
            host = try container.decode(String.self, forKey: hostKey)
            let servicesKey = container.allKeys.first(where: { $0.stringValue == "services" })
            services = try servicesKey.flatMap { try container.decodeIfPresent([String].self, forKey: $0) }
        }
    }
    static func acceptsRequestForTesting(_ data: Data) -> Bool {
        (try? JSONDecoder().decode(Request.self, from: data)) != nil
    }
    private static func answer(_ request: Request, relay: CloudCredentialRelay, expectedInstall: String) async -> JSONValue {
        guard request.host.utf8.count == 25, request.host.hasPrefix("host_"),
              request.host.utf8.dropFirst(5).allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 122) }) else {
            return .object(["ok": .bool(false), "error": .object(["code": .string("validation.invalid"), "message": .string("invalid host")])])
        }
        let answer: CloudCredentialRelay.Answer
        switch request.op {
        case "connect_info":
            guard request.services == nil else { return .object(["ok": .bool(false), "error": .object(["code": .string("validation.invalid"), "message": .string("connect_info does not take services")])]) }
            answer = await relay.linkConnectInfo(host: request.host, expectedInstall: expectedInstall)
        case "link_token":
            guard let services = request.services, !services.isEmpty, Set(services).isSubset(of: ["daemon", "ssh"]), Set(services).count == services.count else { return .object(["ok": .bool(false), "error": .object(["code": .string("validation.invalid"), "message": .string("invalid services")])]) }
            answer = await relay.linkToken(host: request.host, services: services, expectedInstall: expectedInstall)
        default:
            return .object(["ok": .bool(false), "error": .object(["code": .string("operation.unsupported"), "message": .string("unsupported link operation")])])
        }
        if answer.ok { return .object(["ok": .bool(true), "value": answer.body["value"] ?? .null]) }
        return .object(["ok": .bool(false), "error": answer.body])
    }

    private static func stamp(_ pid: pid_t) -> Stamp? {
        var info = proc_bsdinfo()
        let size = Int32(clamping: MemoryLayout<proc_bsdinfo>.size)
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
    private let credentialSocketValue: URL?
    private let clock: any Clock<Duration>

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "cloud.link")
    private static let timeout: Duration = .seconds(30)

    public init(binary: URL, stateRoot: URL?, runtimeBase: URL = DaemonLauncher.userTemporaryDirectory(), tagged: Bool,
         relay: CloudCredentialRelay? = nil, clock: any Clock<Duration> = ContinuousClock()) {
        self.binary = binary
        self.stateRoot = stateRoot
        self.runtimeBase = runtimeBase
        self.tagged = tagged
        if let relay, stateRoot != nil {
            let unique = Self.credentialSocketPath(runtimeBase: runtimeBase)
            self.credentialServer = CloudLinkCredentialServer(path: unique, executable: binary, relay: relay)
            self.credentialSocketValue = URL(fileURLWithPath: unique)
        } else {
            self.credentialServer = nil
            self.credentialSocketValue = nil
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
    var credentialSocket: URL? {
        credentialSocketValue
    }

    /// A unique, short endpoint per launcher instance. Darwin's usual per-user
    /// temporary directory plus this name fits its 104-byte socket path limit.
    static func credentialSocketPath(runtimeBase: URL) -> String {
        let instance = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return runtimeBase.appendingPathComponent("cl-\(instance).sock").path
    }

    static func credentialRequestAcceptedForTesting(_ data: Data) -> Bool {
        CloudLinkCredentialServer.acceptsRequestForTesting(data)
    }

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
        do { try await credentialServer?.start() }
        catch { throw Failure.failed("credential socket unavailable") }
        let result = try await run(ensureArguments(install: install))
        guard let ensured = try? JSONDecoder().decode(Ensured.self, from: Self.lastLine(result.stdout)) else {
            throw Failure.badAnswer
        }
        if credentialServer != nil, ensured.pid == nil { throw Failure.failed("link did not report a pid") }
        credentialServer?.expect(pid: ensured.pid, install: install)
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
