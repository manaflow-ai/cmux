import Darwin
import Foundation
import os

/// Opt-in loopback DevTools endpoint for cmux on iPhone (cmux.json
/// `browser.allowIPhoneAccess`, off by default).
///
/// When the setting is on as Chromium starts, Chromium gets
/// `--remote-debugging-port=<port>` with a free loopback port picked at that
/// moment (never a fixed one). Chromium binds it to 127.0.0.1 only and keeps
/// its default Origin check: no `--remote-allow-origins`, so web pages cannot
/// open the endpoint. A TCP port is required because the reader is a separate
/// process (the cmux on iPhone host) that speaks HTTP `/json/*` and WebSocket;
/// `--remote-debugging-pipe` only serves the process that launched Chromium.
///
/// Chromium reads its switches once per process, so a change takes effect
/// after cmux restarts. The status file next to the Chromium data
/// (`<Application Support>/<bundle id>/devtools.json`, mode 0600) tells the
/// host which case it is in; it is removed on quit. While the endpoint is
/// live it also maps each cmux tab id to its page's DevTools target id
/// (`targets`), asked of each Chromium browser itself on its own in-process
/// DevTools session, never guessed from URLs or titles.
final class CEFRemoteDevTools {
    static let shared = CEFRemoteDevTools()

    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "cef")
    private let statusFile: URL
    /// The setting, as the App last reported it.
    private var requested = false
    /// Whether the App reported the setting yet (nothing is written before).
    private var known = false
    /// The port Chromium was started with; nil when it started without one.
    private var port: UInt16?
    private var startedAt: Date?
    /// Chromium is initialized in this process.
    private var started = false
    /// DevTools target id of each live Chromium browser, with its cmux tab id.
    private var targets: [Int32: CEFRemoteDevToolsTarget] = [:]
    /// Browsers whose target id is being asked for.
    private var asking: Set<Int32> = []
    /// Failed lookups per browser; a browser is asked again on its next
    /// event (navigation, load, visibility) until `maxAttempts`.
    private var failures: [Int32: Int] = [:]
    static let maxAttempts = 8

    init(statusFile: URL = CEFRemoteDevTools.defaultStatusFile()) {
        self.statusFile = statusFile
    }

    nonisolated static func defaultStatusFile(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> URL {
        CEFProfileStorage.forApplication(bundleIdentifier: bundleIdentifier).root
            .deletingLastPathComponent().appending(path: "devtools.json")
    }

    /// The setting changed (or was first read).
    func setRequested(_ value: Bool) {
        requested = value
        known = true
        publish()
    }

    /// Switches for `CefInitialize`: the endpoint's port when the setting is on.
    func startSwitches() -> [String] {
        guard requested, let picked = Self.freeLoopbackPort() else { return [] }
        port = picked
        startedAt = Date()
        return ["remote-debugging-port=\(picked)"]
    }

    /// Runs one in-process DevTools method on a browser and returns its JSON result.
    typealias DevToolsCall = (Int32, String) async throws -> String

    /// After the runtime handled `event`: context start, and browsers that
    /// appeared, moved to another cmux tab, or closed. Nothing happens unless
    /// the endpoint is live, so with the setting off no DevTools call is made.
    func observe(_ event: CEFShimEvent, runtime: CEFRuntime) {
        if case .contextInitialized = event { contextInitialized() }
        guard let browser = event.browserID else { return }
        if case .beforeClose = event { return browserClosed(browser) }
        browserSeen(browser, tabID: runtime.tabsByBrowser[browser]?.id.rawValue) { [weak runtime] browser, method in
            guard let runtime else { throw BrowserTabError.closed }
            return try await runtime.devTools(browser, method: method)
        }
    }

    func browserClosed(_ browser: Int32) {
        failures[browser] = nil
        if targets.removeValue(forKey: browser) != nil { publish() }
    }

    /// An event of `browser`, which belongs to cmux tab `tabID` (nil while no
    /// pane has adopted it). Maps it when it has no target id yet; a failed
    /// lookup is retried on a later event of the same browser. Returns the
    /// lookup's task when one started.
    @discardableResult
    func browserSeen(_ browser: Int32, tabID: String?, devTools: @escaping DevToolsCall) -> Task<Void, Never>? {
        guard requested, port != nil, started, let tabID else { return nil }
        if let known = targets[browser] {
            // The browser now belongs to another cmux tab (adopted, duplicated).
            if known.tabID != tabID {
                targets[browser]?.tabID = tabID
                publish()
            }
            return nil
        }
        guard !asking.contains(browser), failures[browser, default: 0] < Self.maxAttempts else { return nil }
        asking.insert(browser)
        // task-owner: bounded in-process DevTools calls (CEFRuntime.devToolsTimeout each), keyed by browser in `asking`
        return Task { [weak self] in
            let result = await Self.lookUpTargetID(browser, devTools: devTools)
            guard let self else { return }
            self.asking.remove(browser)
            switch result {
            case .success(let targetID):
                self.failures[browser] = nil
                self.targets[browser] = CEFRemoteDevToolsTarget(tabID: tabID, targetID: targetID)
                self.publish()
            case .failure(let reason):
                self.failures[browser, default: 0] += 1
                self.logger.error("devtools.json: no target id for browser \(browser) (attempt \(self.failures[browser] ?? 0)): \(reason, privacy: .public)")
            }
        }
    }

    /// A page target's id is its main frame's id (`Page.getFrameTree`), which
    /// page sessions may read; `Target.getTargetInfo` is refused on the
    /// embedder's page sessions in some Chromium builds, so it is the fallback.
    static func lookUpTargetID(_ browser: Int32, devTools: DevToolsCall) async -> Result<String, LookupFailure> {
        var reasons: [String] = []
        do {
            let json = try await devTools(browser, "Page.getFrameTree")
            if let id = CEFDevToolsResult.mainFrameID(json), !id.isEmpty { return .success(id) }
            reasons.append("Page.getFrameTree: no main frame id")
        } catch {
            reasons.append("Page.getFrameTree: \(error)")
        }
        do {
            let json = try await devTools(browser, "Target.getTargetInfo")
            if let id = CEFRemoteDevToolsStatus.targetID(fromTargetInfo: json) { return .success(id) }
            reasons.append("Target.getTargetInfo: no targetId")
        } catch {
            reasons.append("Target.getTargetInfo: \(error)")
        }
        return .failure(LookupFailure(reason: reasons.joined(separator: "; ")))
    }

    nonisolated struct LookupFailure: Error, CustomStringConvertible {
        var reason: String
        var description: String { reason }
    }

    /// Chromium's context is initialized (the endpoint, if any, is starting).
    func contextInitialized() {
        started = true
        publish()
    }

    /// Quit: no status file means cmux is not running.
    func removeStatus() {
        try? FileManager.default.removeItem(at: statusFile)
    }

    var status: CEFRemoteDevToolsStatus {
        CEFRemoteDevToolsStatus(requested: requested, port: port, started: started, pid: getpid(), startedAt: startedAt,
                                targets: targets.values.sorted { $0.tabID < $1.tabID })
    }

    private func publish() {
        guard known else { return }
        do {
            try status.write(to: statusFile)
        } catch {
            logger.error("devtools.json write failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// A port the kernel picks from its (randomized) ephemeral range on
    /// 127.0.0.1. Chromium binds it a moment later; another process could
    /// take it in between, and Chromium then has no endpoint (the host's
    /// `/json/version` check fails, nothing else changes).
    nonisolated static func freeLoopbackPort() -> UInt16? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        // Never written to; set anyway so no socket here can raise SIGPIPE.
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                bind(fd, raw, length) == 0 && getsockname(fd, raw, &length) == 0
            }
        }
        let port = UInt16(bigEndian: address.sin_port)
        return bound && port != 0 ? port : nil
    }
}

/// What `devtools.json` says. `state`:
/// - `off`: the setting is off and Chromium has no endpoint.
/// - `waitingForBrowser`: the setting is on; the endpoint opens when
///   Chromium starts (the first Chromium tab).
/// - `ready`: `port` is the endpoint (`http://127.0.0.1:<port>/json/version`);
///   `targets` pairs each mapped cmux tab id (the daemon's `tab_…` id) with
///   its page's DevTools `targetId` (`/json/list` `id`, `Target.attachToTarget`).
/// - `restartRequired`: the setting changed after Chromium started; the
///   running Chromium keeps its old state until cmux restarts. No port is
///   published, and a reader must not use an endpoint it found earlier
///   when `enabled` is false.
nonisolated struct CEFRemoteDevToolsStatus: Equatable, Sendable {
    var requested: Bool
    var port: UInt16?
    var started: Bool
    var pid: Int32
    var startedAt: Date?
    var targets: [CEFRemoteDevToolsTarget] = []

    var state: String {
        switch (requested, port, started) {
        case (true, .some, true): "ready"
        case (true, .some, false), (true, .none, false): "waitingForBrowser"
        case (true, .none, true), (false, .some, _): "restartRequired"
        case (false, .none, _): "off"
        }
    }

    /// Sorted-key JSON; `port` and `startedAt` only when `state` is `ready`.
    func json() throws -> Data {
        var object: [String: Any] = ["version": 1, "enabled": requested, "state": state, "pid": Int(pid)]
        if state == "ready", let port {
            object["port"] = Int(port)
            object["startedAt"] = startedAt.map { ISO8601DateFormatter().string(from: $0) }
            object["targets"] = targets.map { ["tabId": $0.tabID, "targetId": $0.targetID] }
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// `targetInfo.targetId` of a `Target.getTargetInfo` result (bare or wrapped in `result`).
    static func targetID(fromTargetInfo json: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return nil }
        let info = (object["targetInfo"] ?? (object["result"] as? [String: Any])?["targetInfo"]) as? [String: Any]
        return (info?["targetId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Writes `json()` atomically, created with mode 0600 (owner only) so no
    /// other account reads it at any point, creating the directory when needed.
    func write(to file: URL) throws {
        let data = try json()
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appending(path: ".\(file.lastPathComponent).\(pid).tmp")
        unlink(temporary.path)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        close(fd)
        guard written == data.count, rename(temporary.path, file.path) == 0 else {
            unlink(temporary.path)
            throw POSIXError(.EIO)
        }
    }
}

/// One cmux tab and its page's DevTools target.
nonisolated struct CEFRemoteDevToolsTarget: Equatable, Sendable {
    var tabID: String
    var targetID: String
}

extension CEFEngine {
    /// cmux.json `browser.allowIPhoneAccess`: Chromium opens a loopback
    /// DevTools endpoint for cmux on iPhone when it starts with this on. A
    /// change after Chromium started takes effect after cmux restarts;
    /// `devtools.json` says which state applies (`CEFRemoteDevToolsStatus`).
    public var allowsIPhoneAccess: Bool {
        get { CEFRemoteDevTools.shared.status.requested }
        set { CEFRemoteDevTools.shared.setRequested(newValue) }
    }

    /// Removes `devtools.json` (quit), so its absence means cmux is not running.
    public func removeIPhoneAccessStatus() {
        CEFRemoteDevTools.shared.removeStatus()
    }
}
