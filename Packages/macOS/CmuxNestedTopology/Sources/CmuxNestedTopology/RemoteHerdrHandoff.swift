public import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Shared plugin ↔ native writer lease and restore handoff.
///
/// Twin of plugin ``cmux_herdr_handoff.py``. Same JSON, same file names,
/// same restore shape (``mode: reattach`` only). Host close always
/// detaches. Does not invent SSH, ``tmux -CC``, or ``kill-server``.
public enum RemoteHerdrHandoff {
    public static let schema = 1
    public static let ownerPlugin = "plugin"
    public static let ownerNative = "native"
    public static let defaultTTLMs = 45_000
    public static let outcomeNativeOwns = "native_owns"
    public static let outcomePluginOwns = "plugin_owns"

    /// Directories both paths read. XDG first; Application Support when present.
    public static func stateDirectories(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        let xdgRoot = environment["XDG_STATE_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".local/state")
        var dirs = [xdgRoot.appendingPathComponent("cmux-herdr")]
        if let override = environment["CMUX_HERDR_NATIVE_STATE_DIR"], !override.isEmpty {
            let extra = URL(fileURLWithPath: override)
            if extra.standardizedFileURL != dirs[0].standardizedFileURL {
                dirs.append(extra)
            }
        } else {
            let mac = home
                .appendingPathComponent("Library")
                .appendingPathComponent("Application Support")
                .appendingPathComponent("cmux-herdr")
            if FileManager.default.fileExists(atPath: mac.path) {
                dirs.append(mac)
            }
        }
        return dirs
    }

    public static func nowMs() -> Int {
        Int(Date().timeIntervalSince1970 * 1000)
    }

    public static func leaseTTLMs(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int {
        if let raw = environment["CMUX_HERDR_LEASE_TTL_MS"], let value = Int(raw) {
            return max(1_000, value)
        }
        return defaultTTLMs
    }

    public static func envTruthy(
        _ name: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        switch (environment[name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on": return true
        default: return false
        }
    }

    public static func pidAlive(_ pid: Int32) -> Bool {
        if pid <= 0 { return false }
        #if canImport(Darwin)
        return kill(pid, 0) == 0 || errno == EPERM
        #else
        return kill(pid, 0) == 0 || errno == EPERM
        #endif
    }
}

/// One writer's claim on a host fingerprint.
public struct RemoteHerdrWriterLease: Hashable, Sendable {
    public var owner: String
    public var pid: Int32
    public var heartbeatMs: Int
    public var fingerprint: String
    public var endpointHash: String
    public var socketPath: String
    public var schema: Int
    public var path: String

    public init(
        owner: String,
        pid: Int32,
        heartbeatMs: Int,
        fingerprint: String,
        endpointHash: String = "",
        socketPath: String = "",
        schema: Int = RemoteHerdrHandoff.schema,
        path: String = ""
    ) {
        self.owner = owner
        self.pid = pid
        self.heartbeatMs = heartbeatMs
        self.fingerprint = fingerprint
        self.endpointHash = endpointHash
        self.socketPath = socketPath
        self.schema = schema
        self.path = path
    }

    public func dictionary() -> [String: Any] {
        [
            "schema": schema,
            "owner": owner,
            "pid": Int(pid),
            "heartbeat_ms": heartbeatMs,
            "fingerprint": fingerprint,
            "endpoint_hash": endpointHash,
            "socket_path": socketPath,
        ]
    }

    public func isFresh(now: Int, ttl: Int = RemoteHerdrHandoff.defaultTTLMs) -> Bool {
        if pid > 0 {
            if !RemoteHerdrHandoff.pidAlive(pid) { return false }
            return (now - heartbeatMs) <= ttl
        }
        return (now - heartbeatMs) <= ttl
    }

    public static func parse(
        _ text: String,
        path: URL,
        fallbackOwner: String? = nil,
        fallbackFingerprint: String = "",
        mtimeMs: Int
    ) -> RemoteHerdrWriterLease? {
        let stripped = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.isEmpty { return nil }
        if let data = stripped.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let owner = object["owner"] as? String,
           owner == RemoteHerdrHandoff.ownerPlugin || owner == RemoteHerdrHandoff.ownerNative
        {
            let pid = intValue(object["pid"])
            var heartbeat = intValue(object["heartbeat_ms"])
            if heartbeat <= 0 { heartbeat = mtimeMs }
            return RemoteHerdrWriterLease(
                owner: owner,
                pid: Int32(pid),
                heartbeatMs: heartbeat,
                fingerprint: (object["fingerprint"] as? String) ?? fallbackFingerprint,
                endpointHash: (object["endpoint_hash"] as? String) ?? "",
                socketPath: (object["socket_path"] as? String) ?? "",
                schema: intValue(object["schema"], default: RemoteHerdrHandoff.schema),
                path: path.path
            )
        }
        let legacy = stripped.lowercased()
        if let fallbackOwner,
           fallbackOwner == RemoteHerdrHandoff.ownerPlugin
            || fallbackOwner == RemoteHerdrHandoff.ownerNative,
           ["1", "live", "yes", "on", "true"].contains(legacy)
        {
            return RemoteHerdrWriterLease(
                owner: fallbackOwner,
                pid: 0,
                heartbeatMs: mtimeMs,
                fingerprint: fallbackFingerprint,
                schema: 0,
                path: path.path
            )
        }
        return nil
    }

    private static func intValue(_ raw: Any?, default fallback: Int = 0) -> Int {
        if let value = raw as? Int { return value }
        if let value = raw as? NSNumber { return value.intValue }
        if let value = raw as? String, let parsed = Int(value) { return parsed }
        return fallback
    }
}

/// Resolved single-writer state for one host.
public struct RemoteHerdrWriterDecision: Hashable, Sendable {
    public var writer: String
    public var owner: String?
    public var nativeLive: Bool
    public var pluginLive: Bool
    public var nativeDetected: Bool
    public var pluginDetected: Bool
    public var forcePlugin: Bool
    public var envNativeLive: Bool
    public var leaseStale: Bool
    public var lease: RemoteHerdrWriterLease?
    public var fingerprint: String

    public var yields: Bool { nativeLive && !forcePlugin }

    public var outcome: String {
        if nativeLive { return RemoteHerdrHandoff.outcomeNativeOwns }
        if pluginLive { return RemoteHerdrHandoff.outcomePluginOwns }
        return "unclaimed"
    }

    public func payload(action: String, method: String? = nil) -> [String: Any] {
        var body: [String: Any] = [
            "ok": true,
            "outcome": (yields || pluginLive) ? outcome : "unclaimed",
            "writer": writer,
            "action": action,
            "server_stopped": false,
            "competing": false,
            "native_live": nativeLive,
            "plugin_live": pluginLive,
            "lease_stale": leaseStale,
            "fingerprint": fingerprint,
        ]
        if let method { body["method"] = method }
        if let lease { body["lease"] = lease.dictionary() }
        return body
    }
}

/// File-backed lease + restore store. Inject directories in tests.
public struct RemoteHerdrHandoffStore: Sendable {
    public var directories: [URL]
    public var nowMs: Int
    public var ttlMs: Int
    public var ourPid: Int32
    public var environment: [String: String]

    public init(
        directories: [URL],
        nowMs: Int = RemoteHerdrHandoff.nowMs(),
        ttlMs: Int = RemoteHerdrHandoff.defaultTTLMs,
        ourPid: Int32 = ProcessInfo.processInfo.processIdentifier,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.directories = directories
        self.nowMs = nowMs
        self.ttlMs = ttlMs
        self.ourPid = ourPid
        self.environment = environment
    }

    public func writerPaths(fingerprint: String, owner: String) -> [URL] {
        directories.flatMap { root in
            [
                root.appendingPathComponent("writer-\(fingerprint).json"),
                root.appendingPathComponent("\(owner)-live-\(fingerprint)"),
                root.appendingPathComponent("\(owner)-live"),
            ]
        }
    }

    public func candidatePaths(fingerprint: String) -> [URL] {
        directories.flatMap { root in
            [
                root.appendingPathComponent("writer-\(fingerprint).json"),
                root.appendingPathComponent("native-live-\(fingerprint)"),
                root.appendingPathComponent("plugin-live-\(fingerprint)"),
                root.appendingPathComponent("native-live"),
                root.appendingPathComponent("plugin-live"),
                root.appendingPathComponent("writer.json"),
            ]
        }
    }

    public func restorePaths(endpointHash: String) -> [URL] {
        directories.map { $0.appendingPathComponent("restore-\(endpointHash).json") }
    }

    public func loadLeases(fingerprint: String) -> [RemoteHerdrWriterLease] {
        candidatePaths(fingerprint: fingerprint).compactMap { readLease($0, fingerprint: fingerprint) }
    }

    public func resolve(fingerprint: String) -> RemoteHerdrWriterDecision {
        let force = RemoteHerdrHandoff.envTruthy("CMUX_HERDR_FORCE_PLUGIN", environment: environment)
        let envNative = RemoteHerdrHandoff.envTruthy("CMUX_HERDR_NATIVE_LIVE", environment: environment)
        let leases = loadLeases(fingerprint: fingerprint)
        let fresh = leases.filter { $0.isFresh(now: nowMs, ttl: ttlMs) }
        let stale = leases.filter { !$0.isFresh(now: nowMs, ttl: ttlMs) }
        let live = fresh.sorted { lhs, rhs in
            if (lhs.owner == RemoteHerdrHandoff.ownerNative) != (rhs.owner == RemoteHerdrHandoff.ownerNative) {
                return lhs.owner == RemoteHerdrHandoff.ownerNative
            }
            return lhs.heartbeatMs > rhs.heartbeatMs
        }.first
        var owner = live?.owner
        if envNative && !force { owner = RemoteHerdrHandoff.ownerNative }
        let nativeLive = owner == RemoteHerdrHandoff.ownerNative && !force
        let pluginLive = owner == RemoteHerdrHandoff.ownerPlugin && !nativeLive
        let writer: String
        if force && (envNative || live?.owner == RemoteHerdrHandoff.ownerNative) {
            writer = "plugin-forced"
        } else if nativeLive {
            writer = RemoteHerdrHandoff.ownerNative
        } else {
            writer = RemoteHerdrHandoff.ownerPlugin
        }
        return RemoteHerdrWriterDecision(
            writer: writer,
            owner: force ? RemoteHerdrHandoff.ownerPlugin : owner,
            nativeLive: nativeLive,
            pluginLive: pluginLive,
            nativeDetected: envNative || leases.contains { $0.owner == RemoteHerdrHandoff.ownerNative },
            pluginDetected: leases.contains { $0.owner == RemoteHerdrHandoff.ownerPlugin },
            forcePlugin: force,
            envNativeLive: envNative,
            leaseStale: live == nil && !stale.isEmpty,
            lease: live,
            fingerprint: fingerprint
        )
    }

    /// Native AppKit claims the host. Yields when a foreign plugin lease is fresh.
    public func claimNative(
        fingerprint: String,
        socketPath: String = "",
        endpointHash: String = "",
        pid: Int32? = nil
    ) -> RemoteHerdrWriterLease? {
        let decision = resolve(fingerprint: fingerprint)
        let pid = pid ?? ourPid
        if decision.pluginLive,
           let lease = decision.lease,
           lease.pid != pid,
           !RemoteHerdrHandoff.envTruthy("CMUX_HERDR_NATIVE_LIVE", environment: environment),
           !decision.forcePlugin
        {
            return nil
        }
        clear(owner: RemoteHerdrHandoff.ownerPlugin, fingerprint: fingerprint)
        return write(
            owner: RemoteHerdrHandoff.ownerNative,
            fingerprint: fingerprint,
            socketPath: socketPath,
            endpointHash: endpointHash,
            pid: pid
        )
    }

    /// Refresh a live native lease so plugin watch does not treat it as stale.
    ///
    /// Lease freshness requires both a live pid **and** a heartbeat within TTL
    /// (same contract as plugin ``heartbeat_plugin_writer``). Call this from the
    /// attach poll/event loop while the mirror is live.
    public func heartbeatNative(
        fingerprint: String,
        socketPath: String = "",
        endpointHash: String = "",
        pid: Int32? = nil
    ) -> RemoteHerdrWriterLease? {
        let pid = pid ?? ourPid
        let decision = resolve(fingerprint: fingerprint)
        if decision.nativeLive {
            if let lease = decision.lease, lease.pid > 0, lease.pid != pid {
                return nil
            }
            return write(
                owner: RemoteHerdrHandoff.ownerNative,
                fingerprint: fingerprint,
                socketPath: socketPath.isEmpty ? (decision.lease?.socketPath ?? "") : socketPath,
                endpointHash: endpointHash.isEmpty ? (decision.lease?.endpointHash ?? "") : endpointHash,
                pid: pid
            )
        }
        // Stale / unclaimed — re-claim (plugin may have briefly resumed).
        return claimNative(
            fingerprint: fingerprint,
            socketPath: socketPath,
            endpointHash: endpointHash,
            pid: pid
        )
    }

    /// Plugin watch / attach claims the host. No-op when native is live.
    public func claimPlugin(
        fingerprint: String,
        socketPath: String = "",
        endpointHash: String = ""
    ) -> RemoteHerdrWriterLease? {
        let decision = resolve(fingerprint: fingerprint)
        if decision.yields { return nil }
        if decision.forcePlugin {
            clear(owner: RemoteHerdrHandoff.ownerNative, fingerprint: fingerprint)
        }
        return write(
            owner: RemoteHerdrHandoff.ownerPlugin,
            fingerprint: fingerprint,
            socketPath: socketPath,
            endpointHash: endpointHash,
            pid: ourPid
        )
    }

    public func releaseNative(fingerprint: String) {
        clear(owner: RemoteHerdrHandoff.ownerNative, fingerprint: fingerprint)
    }

    public func releasePlugin(fingerprint: String) {
        clear(owner: RemoteHerdrHandoff.ownerPlugin, fingerprint: fingerprint)
    }

    public func writeRestore(endpointHash: String, payload: [String: Any]) throws -> String {
        if payload["mode"] as? String == "replay_tree" {
            throw RemoteHerdrHandoffError.replayTree
        }
        var body = payload
        if body["mode"] == nil { body["mode"] = "reattach" }
        var last = ""
        for url in restorePaths(endpointHash: endpointHash) {
            try atomicWrite(url, payload: body)
            last = url.path
        }
        return last
    }

    public func readRestore(endpointHash: String) -> [String: Any]? {
        for url in restorePaths(endpointHash: endpointHash) {
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if object["mode"] as? String == "replay_tree" { continue }
            if let record = RemoteHerdrRestoreRecord.fromDictionary(object) {
                return record.dictionary()
            }
            return object
        }
        return nil
    }

    public func clearRestore(endpointHash: String) -> Bool {
        var removed = false
        for url in restorePaths(endpointHash: endpointHash) {
            if (try? FileManager.default.removeItem(at: url)) != nil {
                removed = true
            }
        }
        return removed
    }

    public func observeForeign(_ decision: RemoteHerdrWriterDecision, method: String) -> [String: Any] {
        var body = decision.payload(action: "observe", method: method)
        body["mirrored"] = true
        body["panes"] = [Any]()
        body["windows"] = [Any]()
        return body
    }

    private func write(
        owner: String,
        fingerprint: String,
        socketPath: String,
        endpointHash: String,
        pid: Int32
    ) -> RemoteHerdrWriterLease {
        let lease = RemoteHerdrWriterLease(
            owner: owner,
            pid: pid,
            heartbeatMs: nowMs,
            fingerprint: fingerprint,
            endpointHash: endpointHash,
            socketPath: socketPath
        )
        var last = ""
        for url in writerPaths(fingerprint: fingerprint, owner: owner) {
            try? atomicWrite(url, payload: lease.dictionary())
            last = url.path
        }
        var written = lease
        written.path = last
        return written
    }

    private func clear(owner: String, fingerprint: String) {
        for url in writerPaths(fingerprint: fingerprint, owner: owner) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func readLease(_ url: URL, fingerprint: String) -> RemoteHerdrWriterLease? {
        guard FileManager.default.fileExists(atPath: url.path),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        let name = url.lastPathComponent
        var fallback: String?
        if name.hasPrefix("native-live") { fallback = RemoteHerdrHandoff.ownerNative }
        if name.hasPrefix("plugin-live") { fallback = RemoteHerdrHandoff.ownerPlugin }
        let mtimeMs: Int
        if let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
           let date = values.contentModificationDate
        {
            mtimeMs = Int(date.timeIntervalSince1970 * 1000)
        } else {
            mtimeMs = nowMs
        }
        return RemoteHerdrWriterLease.parse(
            text,
            path: url,
            fallbackOwner: fallback,
            fallbackFingerprint: fingerprint,
            mtimeMs: mtimeMs
        )
    }

    private func atomicWrite(_ url: URL, payload: [String: Any]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        _ = try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: tmp, to: url)
    }
}

public enum RemoteHerdrHandoffError: Error, Equatable, Sendable {
    case replayTree
}
