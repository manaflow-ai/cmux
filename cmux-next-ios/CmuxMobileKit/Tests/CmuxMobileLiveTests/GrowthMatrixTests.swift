import CmuxMobileAgentChat
import CmuxMobileModel
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

// iOS reliability matrix: memory and disk growth per operation, and a memory
// warning in the middle of a reconnect (cmux-next-ios/reliability-matrix/cells.json,
// axes `growth` and `device`).
//
// Leo, 2026-11-10: "Anything that grows the RAM, the disk for no reason. It
// gets fixed. All of it. Fundamentally." Each growth cell runs one core
// operation 10 times to warm up, then 10 and then 190 more times, and reads
// the process's resident memory (`phys_footprint`, as Xcode's gauge) and the
// size of the app's own cache and data folders after each phase. What a
// session needs once is warm-up; what grows with N is a leak. The bound is a
// fixed amount after warm-up and a per-operation slope between N=10 and
// N=200, so the growth must be constant in N.
//
// No sleeps: the link runs on `LinkTestClock` (virtual time) and the waits
// yield until the condition holds. Each link operation is followed by 30 s of
// virtual time, so a probe or dial race's timeout timer ends the way it does
// on a phone (`LinkController.race` leaves one sleeping until its timeout).
//
// The growth suite measures the whole process, so it runs only in a test run
// of its own (CMUX_GROWTH_MATRIX=1; the matrix workflow passes it as
// TEST_RUNNER_CMUX_GROWTH_MATRIX). In the kit's full run, where other suites
// allocate beside it, it is skipped.

/// Resident memory and the app's disk, read between phases of a growth cell.
enum GrowthProbe {
    static var isolated: Bool { ProcessInfo.processInfo.environment["CMUX_GROWTH_MATRIX"] == "1" }

    static let warmUp = 10
    static let small = 10
    static let large = 200
    /// After warm-up, N=200 may hold this much more than before it ...
    static let memoryBound: Int64 = 8 << 20
    static let diskBound: Int64 = 64 << 10
    /// ... and each operation between N=10 and N=200 at most this much.
    static let memoryPerOperation: Int64 = 4 << 10
    static let diskPerOperation: Int64 = 64

    /// The median of three footprint reads, yielding between them: one read can land on a
    /// fresh allocator region (1 or 8 MiB) that holds no leak.
    @MainActor
    static func settledFootprint() async -> Int64 {
        var reads: [Int64] = []
        for _ in 0 ..< 3 {
            for _ in 0 ..< 20 { await Task.yield() }
            reads.append(footprint())
        }
        return reads.sorted()[1]
    }

    /// The process's footprint in bytes, after the allocator gives back what it can.
    static func footprint() -> Int64 {
        _ = malloc_zone_pressure_relief(nil, 0)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int64(bitPattern: info.phys_footprint) : 0
    }

    /// Every folder and file the app keeps under Caches, Application Support and tmp
    /// (the kit's `FileManager` paths). Not the whole folders: in a test process with no
    /// host app they are the simulator's, shared with the system.
    static var appRoots: [URL] {
        let files = FileManager.default
        let caches = files.urls(for: .cachesDirectory, in: .userDomainMask).first ?? files.temporaryDirectory
        let support = files.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? files.temporaryDirectory
        let tmp = files.temporaryDirectory
        return [
            caches.appending(path: "RowSpill"),
            caches.appending(path: "cmux-mobile-terminal-frames"),
            support.appending(path: "cmux-mobile-live"),
            support.appending(path: "Feed"),
            support.appending(path: "Questions"),
            support.appending(path: "PushRetries"),
            support.appending(path: "ChiefVoiceNotes"),
            support.appending(path: "mac-pins.json"),
            support.appending(path: "cmux-mobile-chief-outbox.json"),
            tmp.appending(path: "cmux-mobile-preview"),
            tmp.appending(path: "cmux-mobile-preview-managed"),
            tmp.appending(path: "cmux-composer-videos"),
        ]
    }

    /// Bytes under `roots` (files, recursively).
    static func diskBytes(_ roots: [URL]) -> Int64 {
        let files = FileManager.default
        var total: Int64 = 0
        for root in roots {
            var isDirectory: ObjCBool = false
            guard files.fileExists(atPath: root.path, isDirectory: &isDirectory) else { continue }
            if !isDirectory.boolValue {
                total += Int64((try? root.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                continue
            }
            guard let walk = files.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { continue }
            for case let url as URL in walk {
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
            }
        }
        return total
    }

    struct Sample {
        var memorySmall: Int64
        var memoryLarge: Int64
        var diskSmall: Int64
        var diskLarge: Int64
        var memoryPerOperation: Int64 { (memoryLarge - memorySmall) / Int64(GrowthProbe.large - GrowthProbe.small) }
        var diskPerOperation: Int64 { (diskLarge - diskSmall) / Int64(GrowthProbe.large - GrowthProbe.small) }
    }

    /// Runs `operation` warm-up, then to N=10, then to N=200 times (its argument is the
    /// running count), reads memory and disk after each phase, prints the cell's MATRIX
    /// line and checks the bounds. `settle` runs before each read (flush a queue).
    @MainActor
    static func check(_ cell: String, roots extra: [URL] = [],
                      settle: @MainActor () async -> Void = {},
                      sourceLocation: SourceLocation = #_sourceLocation,
                      _ operation: @MainActor (Int) async throws -> Void) async throws {
        let roots = appRoots + extra
        var done = 0
        func run(to count: Int) async throws {
            while done < count {
                try await operation(done)
                done += 1
            }
            await settle()
            for _ in 0 ..< 50 { await Task.yield() }
        }
        try await run(to: warmUp)
        let memory0 = await settledFootprint(), disk0 = diskBytes(roots)
        try await run(to: warmUp + small)
        let memory1 = await settledFootprint(), disk1 = diskBytes(roots)
        try await run(to: warmUp + large)
        let memory2 = await settledFootprint(), disk2 = diskBytes(roots)
        let sample = Sample(memorySmall: memory1 - memory0, memoryLarge: memory2 - memory0,
                            diskSmall: disk1 - disk0, diskLarge: disk2 - disk0)
        report(cell, "n10-vs-n200", [
            "mem_n10_kb": sample.memorySmall / 1024, "mem_n200_kb": sample.memoryLarge / 1024,
            "mem_b_per_op": sample.memoryPerOperation,
            "disk_n10_b": sample.diskSmall, "disk_n200_b": sample.diskLarge, "disk_b_per_op": sample.diskPerOperation,
        ])
        #expect(sample.memoryLarge <= memoryBound,
                "\(cell): memory grew \(sample.memoryLarge / 1024) KB over 200 operations after warm-up",
                sourceLocation: sourceLocation)
        #expect(sample.memoryPerOperation <= memoryPerOperation,
                "\(cell): \(sample.memoryPerOperation) bytes of memory per operation (N=10: \(sample.memorySmall / 1024) KB, N=200: \(sample.memoryLarge / 1024) KB)",
                sourceLocation: sourceLocation)
        #expect(sample.diskLarge <= diskBound,
                "\(cell): the app's folders grew \(sample.diskLarge) bytes over 200 operations",
                sourceLocation: sourceLocation)
        #expect(sample.diskPerOperation <= diskPerOperation,
                "\(cell): \(sample.diskPerOperation) bytes of disk per operation (N=10: \(sample.diskSmall), N=200: \(sample.diskLarge))",
                sourceLocation: sourceLocation)
    }

    static func report(_ cell: String, _ variant: String, _ fields: [String: Any]) {
        var line = fields
        line["cell"] = cell
        line["variant"] = variant
        if let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            print("MATRIX \(text)")
        }
    }
}

private struct GrowthTimeout: Error {}

/// Yields (no sleep) until `condition` holds; a wall-clock deadline only guards a hang.
@MainActor
private func until(_ what: @autoclosure () -> String, within: Duration = .seconds(30),
                   sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + within
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("timed out: \(what())", sourceLocation: sourceLocation)
            throw GrowthTimeout()
        }
        await Task.yield()
    }
}

// MARK: Link

/// What every link of a dialer did.
private final class LinkCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var dialCount = 0
    private var closeCount = 0
    private var roamCount = 0
    var dials: Int { lock.withLock { dialCount } }
    var closes: Int { lock.withLock { closeCount } }
    var roams: Int { lock.withLock { roamCount } }
    func dialed() -> Int { lock.withLock { dialCount += 1; return dialCount } }
    func closed() { lock.withLock { closeCount += 1 } }
    func roamed() { lock.withLock { roamCount += 1 } }
}

private final class GrowthLink: MacLink, @unchecked Sendable {
    let transport: CmuxMobileTransport.TransportKind = .wireGuard
    let connectedPath: LinkPathKind? = .direct
    let states: AsyncStream<LinkState>
    private let continuation: AsyncStream<LinkState>.Continuation
    private let counts: LinkCounts
    private let lock = NSLock()
    private var closed = false
    var isClosed: Bool { lock.withLock { closed } }

    init(counts: LinkCounts) {
        self.counts = counts
        (states, continuation) = AsyncStream.makeStream()
        continuation.yield(.connected(.wireGuard, .direct, rttMillis: 5))
    }

    /// The path under the link went away (Wi-Fi lost): the link reports it dropped.
    func drop() { continuation.yield(.disconnected(reason: "network lost")) }

    func openChannel(service: String, args: [String: String]) async throws -> any LinkChannel {
        throw LinkError(code: "unknown_service", message: service)
    }
    func ping() async throws -> UInt32 { 5 }
    func probe(timeout: Duration) async throws -> UInt32? { 5 }
    func close() async {
        let first = lock.withLock { () -> Bool in
            defer { closed = true }
            return !closed
        }
        if first { counts.closed() }
        continuation.finish()
    }
}

/// Every dial connects with a new link; the newest is kept (not every one, which would be
/// the test's own growth). The second dial waits for `release()` when `holdsSecondDial`.
private final class GrowthDialer: MacLinkDialer, @unchecked Sendable {
    let counts = LinkCounts()
    private let holdsSecondDial: Bool
    private let lock = NSLock()
    private var newest: GrowthLink?
    private var held: CheckedContinuation<Void, Never>?
    private var released = false

    init(holdsSecondDial: Bool = false) { self.holdsSecondDial = holdsSecondDial }

    var latest: GrowthLink? { lock.withLock { newest } }
    var isHolding: Bool { lock.withLock { held != nil } }

    func dial(_ endpoint: LinkEndpoint, transport: CmuxMobileTransport.TransportKind, accessToken: String) async throws -> any MacLink {
        let number = counts.dialed()
        if holdsSecondDial, number == 2 {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = lock.withLock { () -> Bool in
                    if released { return true }
                    held = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }
        let link = GrowthLink(counts: counts)
        lock.withLock { newest = link }
        return link
    }

    func release() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released = true
            defer { held = nil }
            return held
        }
        continuation?.resume()
    }

    func networkChanged(baseURL: URL, teamID: String, deviceID: String, accessToken: String) async -> [(String, Double)] {
        counts.roamed()
        return []
    }
}

private let studio = LinkMachine.Target(macID: "m1", name: "Studio", isOnline: true)
private let service = URL(string: "https://example.invalid")!

@MainActor
private func growthController(_ dialer: GrowthDialer, clock: LinkTestClock) -> LinkController {
    let controller = LinkController(transport: .wireGuard, dialer: dialer, clock: clock) { _ in "token" }
    controller.endpoint = { LinkEndpoint(baseURL: service, teamID: "t", deviceID: "d", macDeviceID: $0) }
    return controller
}

/// Virtual time passes between operations: timers that end on a phone end here too.
@MainActor
private func letTimePass(_ clock: LinkTestClock) async {
    clock.advance(by: .seconds(30))
    for _ in 0 ..< 20 { await Task.yield() }
}

// MARK: Workspace deltas

private let deltaSnapshot = #"{"ok":true,"data":{"workspace_revision":1,"workspaces":[{"id":1,"key":"one","name":"First","screens":[{"id":1,"active":true,"active_pane":1,"panes":[{"id":1,"active_tab":0,"tabs":[{"surface":1,"kind":"pty","title":"Before"}]}]}]},{"id":2,"key":"two","name":"Second","screens":[]}]}}"#

@MainActor
private final class LatestTitle {
    var title = ""
}

// MARK: Long chat

/// Turn `n` of a chat whose answers are long tool output (about 1 KB each): five records,
/// seqs 5n+1...5n+5, the shape `LongChatOpenLiveTests.turnRecords` uses.
private func longOutputTurn(_ n: Int) -> [(seq: Int, json: String)] {
    let seq = n * 5 + 1
    let output = String(repeating: "line \(n) of a long build log ", count: 36)
    return [
        (seq, #"{"sessionId":"s1","seq":\#(seq),"at":1,"dir":"mux","kind":"user_message","msg":{"text":"prompt \#(n)","promptId":"p\#(n)","turnId":"t\#(n)"}}"#),
        (seq + 1, #"{"sessionId":"s1","seq":\#(seq + 1),"at":2,"dir":"mux","kind":"turn_started","msg":{"turnId":"t\#(n)"}}"#),
        (seq + 2, #"{"sessionId":"s1","seq":\#(seq + 2),"at":3,"dir":"in","kind":"agent_message_chunk","msg":{"method":"session/update","params":{"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"\#(output)"}}}}}"#),
        (seq + 3, #"{"sessionId":"s1","seq":\#(seq + 3),"at":3,"dir":"in","kind":"agent_message_chunk","msg":{"method":"session/update","params":{"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"done \#(n)"}}}}}"#),
        (seq + 4, #"{"sessionId":"s1","seq":\#(seq + 4),"at":4,"dir":"mux","kind":"turn_result","msg":{"status":"completed","turnId":"t\#(n)"}}"#),
    ]
}

/// The spills the chats made, so a read waits for their writes and deletes.
@MainActor
private final class SpillLog {
    var made: [RowSpill<AgentTurn>] = []
    func flush() {
        for spill in made { spill.flush() }
        made.removeAll()
    }
}

@MainActor
@Suite(.serialized, .enabled(if: GrowthProbe.isolated, "measures the whole process: runs alone (CMUX_GROWTH_MATRIX=1)"))
struct GrowthMatrixTests {
    /// A session opened and closed: dial, connect, close the link, back to idle.
    @Test(.timeLimit(.minutes(5))) func cellGrowthSessionOpenClose() async throws {
        let dialer = GrowthDialer()
        let clock = LinkTestClock()
        let controller = growthController(dialer, clock: clock)
        defer { controller.send(.target(nil)); clock.stop() }
        try await GrowthProbe.check("growth_session_open_close") { done in
            controller.send(.target(studio))
            try await until("open \(done)") { controller.phase.isConnected && dialer.counts.dials == done + 1 }
            controller.send(.target(nil))
            try await until("close \(done)") { controller.phase == .idle && dialer.counts.closes >= done + 1 }
            await letTimePass(clock)
        }
    }

    /// The link drops (the path under it died) and the controller redials and connects.
    @Test(.timeLimit(.minutes(5))) func cellGrowthReconnect() async throws {
        let dialer = GrowthDialer()
        let clock = LinkTestClock()
        let controller = growthController(dialer, clock: clock)
        defer { controller.send(.target(nil)); clock.stop() }
        controller.send(.target(studio))
        try await until("first connect") { controller.phase.isConnected }
        try await GrowthProbe.check("growth_reconnect") { done in
            dialer.latest?.drop()
            try await until("reconnect \(done)") {
                controller.phase.isConnected && dialer.counts.dials == done + 2 && dialer.counts.closes >= done + 1
            }
            await letTimePass(clock)
        }
    }

    /// The phone's network changes under a live link: the controller waits out the burst
    /// (`networkSettle`, virtual time), the dialer roams the link, nothing redials.
    @Test(.timeLimit(.minutes(5))) func cellGrowthNetworkChange() async throws {
        let dialer = GrowthDialer()
        let clock = LinkTestClock()
        let controller = growthController(dialer, clock: clock)
        defer { controller.send(.target(nil)); clock.stop() }
        controller.send(.target(studio))
        try await until("first connect") { controller.phase.isConnected }
        try await GrowthProbe.check("growth_network_change") { done in
            controller.networkChanged(baseURL: service, teamID: "t", deviceID: "d")
            let settled = clock.now.advanced(by: LinkController.networkSettle)
            try await until("settle timer \(done)") { clock.isSleeping(until: settled) }
            clock.advance(by: LinkController.networkSettle)
            try await until("roam \(done)") { dialer.counts.roams == done + 1 }
            await letTimePass(clock)
            #expect(dialer.counts.dials == 1, "a network change redialed a live link")
        }
    }

    /// 1,000 title deltas from the Mac's daemon per operation, applied to the workspace tree.
    @Test(.timeLimit(.minutes(10))) func cellGrowthReceive1000Deltas() async throws {
        let link = MockMacLink { _, data in
            data.split(separator: 0x0A).compactMap { line in
                guard let request = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let id = request["id"] as? String else { return nil }
                let body = request["cmd"] as? String == "list-workspaces" ? deltaSnapshot : #"{"ok":true,"data":{}}"#
                return Data(("{\"id\":\"\(id)\"," + body.dropFirst() + "\n").utf8)
            }
        }
        let sync = WorkspaceSync(deviceID: "test", deviceName: "iPhone")
        await sync.bind(try await link.openChannel(service: "daemon", args: [:]), macID: "mac")
        await sync.refresh()
        let latest = LatestTitle()
        sync.onRows = { tree, _, _ in latest.title = tree.workspaces.first?.tabs.first?.title ?? "" }
        try await GrowthProbe.check("growth_receive_deltas") { done in
            for delta in 0 ..< 1000 {
                sync.handle(.titleChanged(surface: 1, title: "op \(done) delta \(delta)"))
            }
            try await until("1,000 deltas of op \(done)") { latest.title == "op \(done) delta 999" }
        }
        await sync.daemon?.close()
        await sync.bind(nil, macID: "mac")
    }

    /// A long chat (300 turns of long tool output) opened on one bounded read, its older turns
    /// moved to disk as the transcript does when the reader is at the newest, then closed.
    @Test(.timeLimit(.minutes(10))) func cellGrowthOpenLongChat() async throws {
        let records = (0 ..< 300).flatMap(longOutputTurn)
        let spills = SpillLog()
        let spillRoot = FileManager.default.temporaryDirectory.appending(path: "growth-matrix-spill-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: spillRoot) }
        try await GrowthProbe.check("growth_chat_open_long", roots: [spillRoot], settle: { spills.flush() }) { done in
            let requests = LongChatOpenLiveTests.Requests()
            let (hub, store) = try await LongChatOpenLiveTests.open(records, requests)
            store.makeSpill = {
                let spill = RowSpill<AgentTurn>(directory: spillRoot.appending(path: "chat-\(done)"), pageSize: 20, maxRows: 100_000)
                spills.made.append(spill)
                return spill
            }
            try await until("chat \(done) open") { store.turns.last?.id == "t299" }
            store.spillOlder(keeping: 20)
            await hub.bind(nil)
        }
    }
}

// MARK: Device: low memory

/// Device axis, low memory: a memory warning arrives while the link is mid-reconnect (the
/// redial in flight). The warning gives memory back and leaves the reconnect alone: the
/// in-flight dial completes, no second redial, the old link closed.
@MainActor
@Suite struct DeviceAxesLiveTests {
    @Test(.timeLimit(.minutes(1))) func cellDeviceLowMemoryMidReconnect() async throws {
        let dialer = GrowthDialer(holdsSecondDial: true)
        let clock = LinkTestClock()
        let controller = growthController(dialer, clock: clock)
        defer { dialer.release(); controller.send(.target(nil)); clock.stop() }
        controller.send(.target(studio))
        try await until("first connect") { controller.phase.isConnected }
        let first = try #require(dialer.latest)

        first.drop()
        try await until("redial in flight") { dialer.isHolding }
        guard case .connecting = controller.phase else {
            Issue.record("not mid-reconnect: \(controller.phase)")
            return
        }

        // A pressure of its own, relieved directly (as cellAppMemoryWarning does): the system
        // notification would also relieve MemoryPressure.shared under other suites' stores.
        let pressure = MemoryPressure(observesSystem: false)
        let owner = NSObject()
        var relieved = 0
        pressure.register(owner) { relieved += 1 }
        pressure.relieve()
        try await until("memory warning handled") { relieved == 1 }
        if case .connecting = controller.phase {} else {
            Issue.record("the memory warning moved the reconnect to \(controller.phase)")
        }

        dialer.release()
        try await until("reconnected") { controller.phase.isConnected }
        GrowthProbe.report("device_low_memory", "mid-reconnect", [
            "dials": dialer.counts.dials, "relieved": relieved, "old_link_closed": first.isClosed,
        ])
        #expect(dialer.counts.dials == 2, "\(dialer.counts.dials) dials: the warning redialed")
        #expect(first.isClosed, "the dropped link was not closed")
        #expect(controller.link === dialer.latest, "the controller kept another link")
        withExtendedLifetime(owner) {}
    }
}
