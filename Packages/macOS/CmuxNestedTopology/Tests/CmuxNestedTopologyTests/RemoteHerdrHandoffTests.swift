import Foundation
import Testing
@testable import CmuxNestedTopology

@Suite struct RemoteHerdrHandoffTests {
    private func store(
        env: [String: String] = [:],
        now: Int = 1_000_000,
        pid: Int32 = ProcessInfo.processInfo.processIdentifier
    ) throws -> (RemoteHerdrHandoffStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("herdr-handoff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let xdg = root.appendingPathComponent("xdg")
        let native = root.appendingPathComponent("native")
        try FileManager.default.createDirectory(at: xdg, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: native, withIntermediateDirectories: true)
        var environment = env
        environment["XDG_STATE_HOME"] = xdg.path
        environment["CMUX_HERDR_NATIVE_STATE_DIR"] = native.path
        let store = RemoteHerdrHandoffStore(
            directories: [
                xdg.appendingPathComponent("cmux-herdr"),
                native,
            ],
            nowMs: now,
            ttlMs: 45_000,
            ourPid: pid,
            environment: environment
        )
        return (store, root)
    }

    @Test func legacyOneFileIsNativeWhileFresh() throws {
        let (store, _) = try store()
        let path = store.directories[0].appendingPathComponent("native-live-fp")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "1\n".write(to: path, atomically: true, encoding: .utf8)
        let decision = store.resolve(fingerprint: "fp")
        #expect(decision.nativeLive)
        #expect(decision.writer == RemoteHerdrHandoff.ownerNative)
    }

    @Test func staleMtimeDoesNotBlockPlugin() throws {
        let (store, _) = try store(now: 10_000_000)
        let path = store.directories[0].appendingPathComponent("native-live-fp")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "live\n".write(to: path, atomically: true, encoding: .utf8)
        let old = Date(timeIntervalSince1970: 1)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: path.path)
        let decision = store.resolve(fingerprint: "fp")
        #expect(decision.nativeLive == false)
        #expect(decision.leaseStale)
        #expect(decision.writer == RemoteHerdrHandoff.ownerPlugin)
    }

    @Test func deadPidIsImmediatelyStale() throws {
        let (store, _) = try store()
        _ = store.claimNative(fingerprint: "fp", pid: 999_999_999)
        let decision = store.resolve(fingerprint: "fp")
        #expect(decision.nativeLive == false)
        #expect(decision.leaseStale)
    }

    @Test func pluginClaimIsVisibleToNative() throws {
        let (store, _) = try store()
        let lease = store.claimPlugin(fingerprint: "fp", socketPath: "/tmp/herdr.sock")
        #expect(lease != nil)
        let decision = store.resolve(fingerprint: "fp")
        #expect(decision.pluginLive)
        #expect(decision.nativeLive == false)
        let copy = store.directories[1].appendingPathComponent("plugin-live-fp")
        #expect(FileManager.default.fileExists(atPath: copy.path))
    }

    @Test func nativeYieldsWhenOtherPluginIsFresh() throws {
        let (store, _) = try store()
        guard RemoteHerdrHandoff.pidAlive(1) else { return }
        _ = RemoteHerdrHandoffStore(
            directories: store.directories,
            nowMs: store.nowMs,
            ttlMs: store.ttlMs,
            ourPid: 1,
            environment: store.environment
        ).claimPlugin(fingerprint: "fp")
        #expect(store.claimNative(fingerprint: "fp") == nil)
        #expect(store.resolve(fingerprint: "fp").pluginLive)
    }

    @Test func pluginYieldsWhenNativeIsFresh() throws {
        let (store, _) = try store()
        _ = store.claimNative(fingerprint: "fp", pid: store.ourPid)
        #expect(store.claimPlugin(fingerprint: "fp") == nil)
        #expect(store.resolve(fingerprint: "fp").yields)
        #expect(store.resolve(fingerprint: "fp").outcome == RemoteHerdrHandoff.outcomeNativeOwns)
    }

    @Test func envNativeWinsUntilForcePlugin() throws {
        let (nativeStore, _) = try store(env: ["CMUX_HERDR_NATIVE_LIVE": "1"])
        #expect(nativeStore.resolve(fingerprint: "fp").nativeLive)
        let (forced, _) = try store(env: [
            "CMUX_HERDR_NATIVE_LIVE": "1",
            "CMUX_HERDR_FORCE_PLUGIN": "1",
        ])
        #expect(forced.resolve(fingerprint: "fp").nativeLive == false)
        #expect(forced.resolve(fingerprint: "fp").writer == "plugin-forced")
    }

    @Test func restoreRejectsReplayTree() throws {
        let (store, _) = try store()
        var rejected = false
        do {
            _ = try store.writeRestore(endpointHash: "abc", payload: ["mode": "replay_tree"])
        } catch RemoteHerdrHandoffError.replayTree {
            rejected = true
        }
        #expect(rejected)
        let hashed = "deadbeefdeadbeef"
        let bad = store.restorePaths(endpointHash: hashed)[0]
        try FileManager.default.createDirectory(at: bad.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["mode": "replay_tree"]).write(to: bad)
        #expect(store.readRestore(endpointHash: hashed) == nil)
        let path = try store.writeRestore(
            endpointHash: hashed,
            payload: [
                "endpoint_hash": hashed,
                "socket_path": "/tmp/herdr.sock",
                "session_ids": ["main"],
                "target_kind": "contextual",
            ]
        )
        let payload = store.readRestore(endpointHash: hashed)
        #expect(payload?["mode"] as? String == "reattach")
        #expect(store.clearRestore(endpointHash: hashed))
        #expect(FileManager.default.fileExists(atPath: path) == false)
    }

    @Test func observeForeignDoesNotInventGrids() throws {
        let (store, _) = try store()
        _ = store.claimNative(fingerprint: "fp", pid: store.ourPid)
        let body = store.observeForeign(store.resolve(fingerprint: "fp"), method: "remote.herdr.pane_surfaces")
        #expect(body["outcome"] as? String == RemoteHerdrHandoff.outcomeNativeOwns)
        #expect((body["panes"] as? [Any])?.isEmpty == true)
        #expect(body["server_stopped"] as? Bool == false)
    }

    @Test func releasePluginLeavesNative() throws {
        let (store, _) = try store()
        _ = store.claimNative(fingerprint: "fp", pid: store.ourPid)
        store.releasePlugin(fingerprint: "fp")
        #expect(store.resolve(fingerprint: "fp").nativeLive)
    }

    @Test func heartbeatNativeRefreshesWithinTTL() throws {
        var (store, _) = try store(now: 1_000_000)
        _ = store.claimNative(fingerprint: "fp", pid: store.ourPid)
        let first = try #require(store.resolve(fingerprint: "fp").lease?.heartbeatMs)
        store.nowMs = 1_030_000
        let beat = store.heartbeatNative(fingerprint: "fp", pid: store.ourPid)
        #expect(beat?.heartbeatMs == 1_030_000)
        #expect(store.resolve(fingerprint: "fp").nativeLive)
        // Without heartbeat, advancing past TTL would stale; with heartbeat it stays live.
        store.nowMs = 1_030_000 + 40_000
        #expect(store.resolve(fingerprint: "fp").nativeLive)
        _ = first
    }

    @Test func heartbeatNativeDoesNotStealForeignNativePid() throws {
        guard RemoteHerdrHandoff.pidAlive(1) else { return }
        var (store, _) = try store(now: 1_000_000, pid: 1)
        _ = store.claimNative(fingerprint: "fp", pid: 1)
        store.ourPid = ProcessInfo.processInfo.processIdentifier
        store.nowMs = 1_010_000
        #expect(store.heartbeatNative(fingerprint: "fp") == nil)
        #expect(store.resolve(fingerprint: "fp").nativeLive)
    }
}
