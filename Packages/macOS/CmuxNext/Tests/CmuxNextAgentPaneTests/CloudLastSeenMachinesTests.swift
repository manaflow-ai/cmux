import CmuxNextCloud
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The kept Cloud machine list's Swift call sites (``CloudLastSeenMachines``): what is kept and shown for whom, the
/// write skipped for an unchanged list, sign-out's removal (leftover temporary files too), background refreshes
/// spaced out while reads keep failing, and a fresh read (Retry, a pick of a kept row) that waits for the server.
/// The rules are Rust's (cmux-cloud-machine `last_seen`); these run them through the app's FFI.
@MainActor
struct CloudLastSeenMachinesTests {
    typealias Machine = AgentPaneCloudMachines.Machine

    private final class Clock { var now = Date(timeIntervalSince1970: 1_800_000_000) }
    /// What a test's refresh did: how often it ran and what it answers.
    private final class Refreshes {
        var count = 0
        var lands = false
        var release: CheckedContinuation<Void, Never>?
    }

    private let account: [String?] = ["u-last-seen", "t-last-seen"]
    private let machines = [Machine(id: "m1", name: "build box", stage: "paused"),
                            Machine(id: "m2", name: "gpu", stage: "ready", size: .init(cpu: 8, memoryMb: 32_768, diskMb: nil))]

    private func fixture(shows: Bool = true) throws -> (CloudLastSeenMachines, URL, Clock, UserDefaults) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-last-seen-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let suite = "CloudLastSeenMachinesTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(shows, forKey: CloudLastSeenMachines.showKey)
        let clock = Clock()
        return (CloudLastSeenMachines(stateDirectory: dir, defaults: defaults, now: { clock.now }), dir, clock, defaults)
    }

    private func files(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("cloud-last-seen").path)) ?? []).sorted()
    }

    private func kept(_ dir: URL) throws -> String {
        let name = try #require(files(dir).first { $0.hasSuffix(".json") })
        return try String(contentsOf: dir.appendingPathComponent("cloud-last-seen").appendingPathComponent(name), encoding: .utf8)
    }

    @Test func keepsAndShowsTheListForItsAccountOnly() async throws {
        let (lastSeen, dir, clock, defaults) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        lastSeen.keep(machines, for: account)
        await lastSeen.settled()
        let shown = try #require(lastSeen.shown(for: account))
        #expect(shown.machines == machines)
        #expect(shown.at == clock.now)
        #expect(lastSeen.shown(for: ["u-last-seen", "another-team"]) == nil)
        #expect(lastSeen.shown(for: ["someone-else", "t-last-seen"]) == nil)
        // Signed out keeps nothing; off (the default) shows nothing, though the list is still kept.
        lastSeen.keep(machines, for: [nil, nil])
        await lastSeen.settled()
        #expect(files(dir).count == 1)
        defaults.set(false, forKey: CloudLastSeenMachines.showKey)
        #expect(lastSeen.shown(for: account) == nil)
        let refreshes = Refreshes()
        #expect(await lastSeen.inventory(for: account, team: nil, teams: []) { refreshes.count += 1; return true } == nil)
        #expect(refreshes.count == 0)
    }

    @Test func anUnchangedListIsNotWrittenAgain() async throws {
        let (lastSeen, dir, clock, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        lastSeen.keep(machines, for: account)
        await lastSeen.settled()
        let first = try kept(dir)
        // The picker's next reads a minute on: the same rows, not written again (the file keeps its time).
        clock.now += 60
        lastSeen.keep(machines, for: account)
        await lastSeen.settled()
        #expect(try kept(dir) == first)
        #expect(lastSeen.shown(for: account)?.at == Date(timeIntervalSince1970: 1_800_000_000))
        // A change is written.
        clock.now += 60
        lastSeen.keep([machines[0]], for: account)
        await lastSeen.settled()
        #expect(try kept(dir) != first)
        #expect(lastSeen.shown(for: account)?.machines == [machines[0]])
        // So is the same list an hour on, so an app left running never ages out its own list.
        let changed = try kept(dir)
        clock.now += 3600
        lastSeen.keep([machines[0]], for: account)
        await lastSeen.settled()
        #expect(try kept(dir) != changed)
    }

    @Test func forgetRemovesKeptListsAndLeftoverTemporaryFiles() async throws {
        let (lastSeen, dir, _, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        lastSeen.keep(machines, for: account)
        await lastSeen.settled()
        let folder = dir.appendingPathComponent("cloud-last-seen")
        let name = try #require(files(dir).first)
        // A write interrupted between its write and its rename, and a file that is not the list's.
        try Data("{".utf8).write(to: folder.appendingPathComponent("\(name).4242.tmp"))
        try Data("{}".utf8).write(to: folder.appendingPathComponent("notes.json"))
        lastSeen.forget()
        await lastSeen.settled()
        #expect(files(dir) == ["notes.json"])
        #expect(lastSeen.shown(for: account) == nil)
    }

    @Test func backgroundRefreshesBackOffWhileReadsFail() async throws {
        let (lastSeen, dir, clock, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        lastSeen.keep(machines, for: account)
        await lastSeen.settled()
        let refreshes = Refreshes()
        let refresh: @MainActor () async -> Bool = { refreshes.count += 1; return refreshes.lands }
        func plain() async -> AgentPaneCloudMachines.Inventory? {
            let inventory = await lastSeen.inventory(for: account, team: nil, teams: [], refresh: refresh)
            await lastSeen.settled()
            return inventory
        }
        // The kept list answers at once, marked last seen, never complete; a refresh starts behind it.
        let first = try #require(await plain())
        #expect(first.lastSeenAt != nil && !first.complete && first.machines == machines)
        #expect(refreshes.count == 1)
        // Failed once: the next waits 2 s, then 4 s after the second failure.
        clock.now += 1
        _ = await plain()
        #expect(refreshes.count == 1)
        clock.now += 1
        _ = await plain()
        #expect(refreshes.count == 2)
        clock.now += 3
        _ = await plain()
        #expect(refreshes.count == 2)
        clock.now += 1
        _ = await plain()
        #expect(refreshes.count == 3)
        // A fresh read (Retry, a pick) never waits on the backoff, and waits for its read: still failing, the kept list.
        let stillKept = await lastSeen.inventory(for: account, team: nil, teams: [], fresh: true, refresh: refresh)
        #expect(refreshes.count == 4 && stillKept?.lastSeenAt != nil)
        // It lands: nil (the caller answers the fresh list), and the backoff starts over.
        refreshes.lands = true
        #expect(await lastSeen.inventory(for: account, team: nil, teams: [], fresh: true, refresh: refresh) == nil)
        #expect(refreshes.count == 5)
        _ = await plain()
        #expect(refreshes.count == 6)
    }

    @Test func aFreshReadJoinsTheRefreshInFlight() async throws {
        let (lastSeen, dir, _, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        lastSeen.keep(machines, for: account)
        await lastSeen.settled()
        let refreshes = Refreshes()
        // The first read hangs until released; any other lands at once.
        let slow: @MainActor () async -> Bool = {
            refreshes.count += 1
            if refreshes.count == 1 { await withCheckedContinuation { refreshes.release = $0 } }
            return true
        }
        _ = await lastSeen.inventory(for: account, team: nil, teams: [], refresh: slow)
        while refreshes.release == nil { await Task.yield() }
        let fresh = Task { await lastSeen.inventory(for: account, team: nil, teams: [], fresh: true, refresh: slow) }
        for _ in 0..<20 { await Task.yield() }
        refreshes.release?.resume()
        #expect(await fresh.value == nil)
        #expect(refreshes.count == 1)
    }

    @Test func aFreshListRequestUsesTheFreshList() async throws {
        let cloud = AgentPaneCloudMachines()
        cloud.list = { .init(signedIn: true, loaded: true, machines: [], account: ["u", nil], lastSeenAt: Date(timeIntervalSince1970: 1_800_000_000)) }
        // No fresh list: the plain one (a kept list, marked last seen and never complete).
        let plain = try #require(await AgentPaneCloudMachineRequest.freshList.reply(cloud, gestures: AgentPaneUserGestures())["value"] as? [String: Any])
        #expect(plain["lastSeenAt"] as? Double == 1_800_000_000_000 && plain["complete"] as? Bool == false)
        cloud.freshList = { .init(signedIn: true, loaded: true, machines: [Machine(id: "m1", name: "box", stage: "ready")], account: ["u", nil], complete: true) }
        let fresh = try #require(await AgentPaneCloudMachineRequest.freshList.reply(cloud, gestures: AgentPaneUserGestures())["value"] as? [String: Any])
        #expect(fresh["lastSeenAt"] == nil && fresh["complete"] as? Bool == true)
        #expect((fresh["machines"] as? [[String: Any]])?.first?["id"] as? String == "m1")
        // A plain list still answers the plain one.
        let list = try #require(await AgentPaneCloudMachineRequest.list.reply(cloud, gestures: AgentPaneUserGestures())["value"] as? [String: Any])
        #expect(list["lastSeenAt"] != nil)
    }
}
