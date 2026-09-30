import CmuxNextDaemon
import Foundation
import Synchronization
import Testing
@testable import CmuxNextBridge

/// Deterministic xorshift so failures reproduce from the printed seed.
nonisolated struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

private nonisolated func token(_ n: Int) -> Data { withUnsafeBytes(of: UInt64(n).bigEndian) { Data($0) } }

private nonisolated func tokens(in data: Data) -> [Int] {
    stride(from: 0, to: data.count, by: 8).map { offset in
        data[data.startIndex + offset ..< data.startIndex + offset + 8].reduce(0) { $0 << 8 | Int($1) }
    }
}

/// Random event sequences against the pure reducer, with a simulated daemon
/// that completes opens, delivers replays and overflows links in any order.
struct TerminalAttachReducerStressTests {
    typealias Machine = TerminalAttachMachine<Int>

    private struct World {
        var machine = Machine(initialSize: CellSize(cols: 80, rows: 24))
        var inFlight: [Int: CellSize] = [:]      // attempt -> size
        var links: [Int: (replayed: Bool, detached: Int)] = [:]
        var accepted: Set<Int> = []              // links the machine adopted
        var nextLink = 1
        var typed: [Int] = []
        var typedBeforeEnd: [Int] = []
        var sent: [Int] = []
        var ended = false
        var finishes = 0

        mutating func apply(_ effects: [Machine.Effect]) {
            for effect in effects {
                switch effect {
                case .open(let attempt, let size):
                    #expect(inFlight[attempt] == nil)
                    inFlight[attempt] = size
                case .cancelOpen(let attempt):
                    #expect(inFlight[attempt] != nil)
                case .send(let link, let data):
                    #expect(links[link]?.replayed == true, "input before the replay")
                    #expect(links[link]?.detached == 0, "input to a detached link")
                    sent += tokens(in: data)
                case .resize(let link, _), .claim(let link, _), .release(let link):
                    #expect(links[link]?.replayed == true, "geometry before the replay")
                    #expect(links[link]?.detached == 0, "geometry on a detached link")
                case .detach(let link):
                    links[link]?.detached += 1
                case .finish:
                    finishes += 1
                }
            }
        }

        mutating func send(_ event: Machine.Event) {
            let wasClosed = machine.isClosed
            apply(machine.reduce(event))
            if !wasClosed, machine.isClosed { ended = true }
        }
    }

    @Test(arguments: 0..<400)
    func randomSequencesNeverLoseDuplicateOrLeak(seed: Int) {
        var random = SeededRandom(seed: UInt64(seed) &* 0x2545_F491_4F6C_DD1D &+ 1)
        var world = World()
        world.send(.start)
        var counter = 0
        for _ in 0..<Int.random(in: 20...200, using: &random) {
            switch Int.random(in: 0..<100, using: &random) {
            case 0..<35:
                counter += 1
                world.typed.append(counter)
                if !world.machine.isClosed { world.typedBeforeEnd.append(counter) }
                world.send(.input(token(counter)))
            case 35..<45:
                world.send(.resize(CellSize(cols: .random(in: 20...200, using: &random),
                                            rows: .random(in: 5...60, using: &random))))
            case 45..<52:
                world.send(.visibility(.random(using: &random)))
            case 52..<70:
                // Complete an in-flight open (rarely failing).
                guard let attempt = world.inFlight.keys.randomElement(using: &random) else { continue }
                world.inFlight[attempt] = nil
                if Int.random(in: 0..<40, using: &random) == 0 {
                    world.send(.openFailed(attempt: attempt))
                } else {
                    let link = world.nextLink
                    world.nextLink += 1
                    world.links[link] = (false, 0)
                    world.send(.opened(link, attempt: attempt))
                }
            case 70..<85:
                // The daemon delivers the replay of an open, attached link.
                let candidates = world.links.filter { !$0.value.replayed && $0.value.detached == 0 }.keys
                guard let link = candidates.randomElement(using: &random) else { continue }
                world.links[link]?.replayed = true
                world.send(.replayDelivered(link))
            case 85..<95:
                // Overflow (or a stale end) on any link.
                guard let link = world.links.keys.randomElement(using: &random) else { continue }
                world.send(.ended(link, Int.random(in: 0..<15, using: &random) == 0 ? .surfaceGone : .overflow))
            case 95..<97:
                world.send(.close)
            default:
                // Duplicate or stale notifications (already replayed or detached links).
                let stale = world.links.filter { $0.value.replayed || $0.value.detached > 0 }.keys
                guard let link = stale.randomElement(using: &random) else { continue }
                world.send(.replayDelivered(link))
            }
        }
        // Quiesce: finish every open still in flight, then close.
        world.send(.close)
        for attempt in world.inFlight.keys.sorted() {
            world.inFlight[attempt] = nil
            let link = world.nextLink
            world.nextLink += 1
            world.links[link] = (false, 0)
            world.send(.opened(link, attempt: attempt))
        }

        // No duplicate or reordered input: what went out is exactly a prefix
        // of what was typed before the attachment ended, in order...
        #expect(world.sent == Array(world.typedBeforeEnd.prefix(world.sent.count)), "seed \(seed)")
        // ...and nothing typed before the end was lost except what was
        // still queued when the attachment ended for good (counted).
        let lost = world.typed.count - world.sent.count
        #expect(world.machine.droppedInputBytes == lost * 8, "seed \(seed)")
        #expect(world.machine.queuedInput.isEmpty)
        // No leaked attachment: every link was detached exactly once.
        for (link, state) in world.links {
            #expect(state.detached == 1, "link \(link) detached \(state.detached)x, seed \(seed)")
        }
        #expect(world.finishes == 1, "seed \(seed)")
        #expect(world.machine.isClosed)
    }

    /// Without close or failure, every keystroke arrives exactly once.
    @Test(arguments: 0..<200)
    func withoutATerminalEndNothingIsLost(seed: Int) {
        var random = SeededRandom(seed: UInt64(seed) &+ 0xABCDEF)
        var world = World()
        world.send(.start)
        var counter = 0
        for _ in 0..<150 {
            switch Int.random(in: 0..<10, using: &random) {
            case 0..<5:
                counter += 1
                world.send(.input(token(counter)))
            case 5:
                world.send(.resize(CellSize(cols: .random(in: 20...200, using: &random), rows: 30)))
            case 6:
                guard let attempt = world.inFlight.keys.first else { continue }
                world.inFlight[attempt] = nil
                world.links[world.nextLink] = (false, 0)
                world.send(.opened(world.nextLink, attempt: attempt))
                world.nextLink += 1
            case 7:
                let candidates = world.links.filter { !$0.value.replayed && $0.value.detached == 0 }.keys
                guard let link = candidates.first else { continue }
                world.links[link]?.replayed = true
                world.send(.replayDelivered(link))
            case 8:
                // Overflow only live links, so the failure budget never runs out.
                guard let link = world.machine.liveLink else { continue }
                world.send(.ended(link, .overflow))
            default:
                world.send(.visibility(.random(using: &random)))
            }
        }
        // Drive to live.
        while world.machine.liveLink == nil {
            if let attempt = world.inFlight.keys.first {
                world.inFlight[attempt] = nil
                world.links[world.nextLink] = (false, 0)
                world.send(.opened(world.nextLink, attempt: attempt))
                world.nextLink += 1
            } else if let link = world.links.first(where: { !$0.value.replayed && $0.value.detached == 0 })?.key {
                world.links[link]?.replayed = true
                world.send(.replayDelivered(link))
            }
        }
        #expect(world.sent == (0..<counter).map { $0 + 1 }, "seed \(seed)")
        #expect(world.machine.droppedInputBytes == 0)
        let open = world.links.filter { $0.value.detached == 0 }.map(\.key)
        #expect(open == [world.machine.liveLink!], "only the live link stays attached, seed \(seed)")
    }
}

// MARK: - Driver under real concurrency

/// Fake daemon attachment: records every command, delivers a replay when the
/// test says so, and finishes its stream when detached.
nonisolated final class FakeLink: TerminalAttachLink, @unchecked Sendable {
    let id: Int
    let events: AsyncStream<TerminalChannelEvent>
    private let continuation: AsyncStream<TerminalChannelEvent>.Continuation
    private struct Log {
        var input = Data()
        var commands: [String] = []
        var detaches = 0
        var lateInput = 0
    }
    private let log = Mutex(Log())

    init(id: Int) {
        self.id = id
        (events, continuation) = AsyncStream.makeStream(of: TerminalChannelEvent.self, bufferingPolicy: .bufferingNewest(4096))
    }

    var input: Data { log.withLock { $0.input } }
    var commands: [String] { log.withLock { $0.commands } }
    /// 0 or 1: `detachNow` is idempotent, like the real attachment.
    var detaches: Int { log.withLock { $0.detaches } }
    /// Input that arrived after the detach (must stay 0).
    var lateInput: Int { log.withLock { $0.lateInput } }

    func emit(_ event: TerminalChannelEvent) { continuation.yield(event) }

    func sendInput(_ data: Data) {
        log.withLock {
            if $0.detaches > 0 { $0.lateInput += 1 }
            $0.input.append(data)
        }
    }
    func sendResize(_ size: CellSize) { log.withLock { $0.commands.append("resize \(size.cols)x\(size.rows)") } }
    func sendClaim(reporting size: CellSize) { log.withLock { $0.commands.append("claim \(size.cols)x\(size.rows)") } }
    func sendReleaseGeometry() { log.withLock { $0.commands.append("release") } }
    func detachNow() {
        let first = log.withLock { log -> Bool in
            defer { log.detaches = 1 }
            return log.detaches == 0
        }
        guard first else { return }
        continuation.yield(.closed(.detachedByClient))
        continuation.finish()
    }
}

/// Hands out fake links; each open waits a random number of scheduler turns
/// and may fail.
nonisolated final class FakeDaemon: @unchecked Sendable {
    private struct State {
        var links: [FakeLink] = []
        var random: SeededRandom
        var failEvery: Int
    }
    private let state: Mutex<State>

    init(seed: UInt64, failEvery: Int = 0) {
        state = Mutex(State(random: SeededRandom(seed: seed), failEvery: failEvery))
    }

    var links: [FakeLink] { state.withLock { $0.links } }

    func open(size: CellSize) async throws -> FakeLink {
        let (turns, fail, link) = state.withLock { state -> (Int, Bool, FakeLink) in
            let link = FakeLink(id: state.links.count + 1)
            let fail = state.failEvery > 0 && Int.random(in: 0..<state.failEvery, using: &state.random) == 0
            if !fail { state.links.append(link) }
            return (Int.random(in: 0..<20, using: &state.random), fail, link)
        }
        for _ in 0..<turns { await Task.yield() }
        if fail { throw CancellationError() }
        // The daemon's first event on every attach is the replay.
        link.emit(.replay(TerminalReplay(cols: size.cols, rows: size.rows, data: Data("R\(link.id)".utf8))))
        return link
    }
}

@Suite(.timeLimit(.minutes(2)))
struct TerminalAttachDriverStressTests {
    typealias Driver = TerminalAttachDriver<FakeLink>

    /// Polls `condition` with short deterministic waits (test-only).
    private func eventually(_ what: String, _ condition: () -> Bool) async {
        for _ in 0..<2000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("timed out waiting for \(what)")
    }

    private func consume(_ driver: Driver) -> Task<[TerminalStreamPlan.Step], Never> {
        Task.detached {
            var steps: [TerminalStreamPlan.Step] = []
            while let step = await driver.nextStep() { steps.append(step) }
            return steps
        }
    }

    @Test(arguments: 0..<40)
    func concurrentEventsNeverLoseDuplicateOrLeak(seed: Int) async {
        let daemon = FakeDaemon(seed: UInt64(seed) + 1)
        let driver = Driver(initialSize: CellSize(cols: 80, rows: 24), opener: { try await daemon.open(size: $0) })
        let consumer = consume(driver)
        driver.start()

        let typedCount = 300
        // One typist (Ghostty's writer is one ordered stream)...
        let typist = Task.detached {
            for n in 1...typedCount {
                driver.input(token(n))
                if n % 7 == 0 { await Task.yield() }
            }
        }
        // ...racing geometry and visibility from the main actor...
        let layout = Task { @MainActor in
            var random = SeededRandom(seed: UInt64(seed) &+ 99)
            for _ in 0..<120 {
                if Bool.random(using: &random) {
                    driver.resize(CellSize(cols: .random(in: 20...200, using: &random), rows: 30))
                } else {
                    driver.setVisible(.random(using: &random))
                }
                await Task.yield()
            }
            driver.setVisible(true)
            driver.resize(CellSize(cols: 111, rows: 33))
        }
        // ...and daemon overflows on whichever link is live.
        let overflow = Task.detached {
            var random = SeededRandom(seed: UInt64(seed) &+ 7)
            for _ in 0..<6 {
                for _ in 0..<Int.random(in: 5...40, using: &random) { await Task.yield() }
                if let ref = driver.machine.liveLink { ref.link.emit(.closed(.overflow)) }
            }
        }
        await typist.value
        await layout.value
        await overflow.value
        await eventually("live") { driver.machine.liveLink != nil && driver.machine.queuedInput.isEmpty }

        let links = daemon.links
        let delivered = links.reduce(into: Data()) { $0.append($1.input) }
        #expect(tokens(in: delivered) == Array(1...typedCount), "seed \(seed): lost, duplicated or reordered input")
        // The final geometry reached the live link last.
        let live = driver.machine.liveLink!.link
        let lastGeometry = live.commands.last { $0.hasPrefix("resize") || $0.hasPrefix("claim") }
        #expect(lastGeometry?.hasSuffix("111x33") == true, "seed \(seed): \(live.commands)")
        // Only the live link is attached; every overflowed one was detached once.
        for link in links where link !== live {
            #expect(link.detaches == 1, "seed \(seed): link \(link.id) detached \(link.detaches)x")
        }

        driver.close()
        await eventually("tasks finished") { driver.runningTasks == 0 }
        for link in daemon.links {
            #expect(link.detaches == 1, "seed \(seed): link \(link.id) leaked")
            #expect(link.lateInput == 0, "seed \(seed): input after detach on link \(link.id)")
        }
        _ = await consumer.value
        #expect(driver.machine.isClosed)
    }

    @Test(arguments: 0..<40)
    func closingAtARandomMomentFreesEverything(seed: Int) async {
        let daemon = FakeDaemon(seed: UInt64(seed) + 1000, failEvery: 9)
        let driver = Driver(initialSize: CellSize(cols: 80, rows: 24), opener: { try await daemon.open(size: $0) })
        let consumer = consume(driver)
        driver.start()
        var random = SeededRandom(seed: UInt64(seed) &+ 5)
        let closeAfter = Int.random(in: 0..<60, using: &random)
        for step in 0..<60 {
            if step == closeAfter { driver.close() }
            driver.input(token(step))
            if step % 10 == 3, let ref = driver.machine.liveLink { ref.link.emit(.closed(.overflow)) }
            await Task.yield()
        }
        driver.close()
        await eventually("tasks finished") { driver.runningTasks == 0 }
        for link in daemon.links { #expect(link.detaches == 1, "seed \(seed): link \(link.id) detached \(link.detaches)x") }
        _ = await consumer.value
    }

    @Test func droppingTheDriverDetachesItsLink() async {
        let daemon = FakeDaemon(seed: 3)
        var driver: Driver? = Driver(initialSize: CellSize(cols: 80, rows: 24), opener: { try await daemon.open(size: $0) })
        driver?.start()
        await eventually("live") { driver?.machine.liveLink != nil }
        driver = nil
        await eventually("detached") { daemon.links.allSatisfy { $0.detaches == 1 } }
    }

    @Test func outputIsBoundedWhileTheViewDoesNotDrain() async {
        let daemon = FakeDaemon(seed: 4)
        let driver = Driver(initialSize: CellSize(cols: 80, rows: 24), outputHighWater: 64 << 10,
                            opener: { try await daemon.open(size: $0) })
        driver.start()
        await eventually("live") { driver.machine.liveLink != nil }
        let link = driver.machine.liveLink!.link
        let chunk = Data(count: 16 << 10)
        for _ in 0..<64 { link.emit(.output(chunk, colors: nil)) }
        // The pump stops at the high-water mark instead of buffering 1 MiB.
        await eventually("pump parked") { driver.bufferedOutputBytes > 64 << 10 }
        for _ in 0..<50 { await Task.yield() }
        #expect(driver.bufferedOutputBytes <= (64 << 10) + chunk.count)
        // Draining resumes it; the replay comes first, then all output in order.
        var outputBytes = 0
        var sawReplay = false
        while outputBytes < 64 * chunk.count, let step = await driver.nextStep() {
            switch step {
            case .replay: sawReplay = true
            case .output(let data): outputBytes += data.count
            default: break
            }
        }
        #expect(sawReplay)
        #expect(outputBytes == 64 * chunk.count)
        driver.close()
    }
}

struct TerminalStepQueueTests {
    @Test func aReplaySupersedesQueuedOutputButKeepsGrids() async {
        let queue = TerminalStepQueue(highWater: 1 << 20)
        await queue.push(.output(Data("old".utf8)))
        await queue.push(.grid(columns: 90, rows: 30))
        let replay = TerminalReplay(cols: 90, rows: 30, data: Data("R".utf8))
        await queue.push(.replay(replay))
        await queue.push(.output(Data("new".utf8)))
        queue.finish()
        var steps: [TerminalStreamPlan.Step] = []
        while let step = await queue.next() { steps.append(step) }
        #expect(steps == [.grid(columns: 90, rows: 30), .replay(replay), .output(Data("new".utf8))])
    }

    @Test func finishReleasesAParkedProducer() async {
        let queue = TerminalStepQueue(highWater: 4)
        await queue.push(.output(Data(count: 8)))
        let producer = Task { await queue.push(.output(Data(count: 8))) }
        for _ in 0..<20 { await Task.yield() }
        queue.finish()
        await producer.value
        #expect(queue.bufferedOutputBytes == 8)
    }
}
