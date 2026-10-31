@testable import CmuxNextServer
import Foundation
import Testing
@testable import CmuxNextApp

/// The consent state machine under a deterministic scheduler. Each run picks two to five requests (with
/// repeats) from reads, Mac Screen tickets (View Only and Full Control), grants and revokes of either
/// surface, the sheet's Allow and Deny, the Labs switch turning off, and changes acpmux makes on its own
/// (the Mac joining or leaving, reads starting or stopping to fail, each followed by the read the folder
/// watch makes), over a random acpmux state (granted or not, joined or not, reads failing or not, the
/// consent capability or not, the line proved as the person or not). Every acpmux boundary a request
/// reaches (the join status, opening the line, the record read, the write) waits until the scheduler
/// releases it, and the scheduler interleaves starts and releases in a seeded random order. A record
/// read's reply is taken either when it is asked or when it is released (seeded), so a reply taken
/// before a change and delivered after it is the stale one it would be. The runs are sampled, not every
/// schedule. After every step, once each started request is again waiting or done, the invariants are
/// checked:
/// - What the model allows Mac Screen is never more than a read of acpmux can see (no stale grant, a revoke
///   narrows the moment it starts, an unread record allows nothing, a write's answer allows nothing). After
///   a change acpmux made on its own this holds again once the reads under way and the folder watch's
///   read are done (the app can't know before a read).
/// - A ticket serves only on its own read, at the current generation, that got through and grants its
///   scope, with no write in flight; otherwise it is refused.
/// - One write at a time: a second one is refused as busy; a grant is never sent with the Labs switch off
///   (recorded where the line writes its bytes, after the write's boundary), nor without the device owner's confirm (which the scheduler answers confirmed, cancelled or
///   unavailable, seeded, and releases like any other boundary).
/// - A press during a write does nothing: a Deny never closes the sheet over it, an Allow never writes.
/// - When all is done, no write is in flight and one more read brings the model to what acpmux holds.
@MainActor @Suite(.serialized) struct JoinConsentInterleavingTests {
    enum Op: CaseIterable {
        case read, ticketView, ticketFull, grantScreen, grantControl, revokeScreen, revokeControl, allow, deny, labsOff
        /// acpmux on its own: the Mac joins or leaves; reads start or stop failing; the person turns Screen
        /// sharing off elsewhere.
        case joinFlip, readFlip, revokeElsewhere
    }

    /// What acpmux holds.
    struct Truth {
        var screen: Bool
        var control: Bool
        var joined: Bool
        var consentRequired: Bool?
        var readFails: Bool
        var capable = true
        var person = true

        /// What Mac Screen may serve: a grant a read can see (a failing read sees none).
        func allows(full: Bool) -> Bool {
            capable && !readFails && (consentRequired == false || (screen && (!full || control)))
        }
    }

    nonisolated enum Current {
        /// The request a boundary belongs to.
        @TaskLocal static var op: Int?
    }

    @MainActor final class World {
        var truth: Truth
        var enabled = true
        var askShown = false
        var gating = false
        var waiting: [(op: Int, gate: JoinConsentTests.Gate)] = []
        var started: Set<Int> = []
        var done: Set<Int> = []
        /// Each write acpmux received, and whether the Labs switch was on when it was sent.
        var sends: [(write: String, enabled: Bool)] = []
        /// What each request's latest record read answered (nil: the read failed).
        var reads: [Int: JoinConsentRecord?] = [:]
        /// Whether a record read takes its reply when asked (else when released).
        var early: () -> Bool = { false }
        /// acpmux changed on its own and the reads that may not have seen it are not all done.
        var changedOnItsOwn = false
        /// The device owner's answer to each grant's confirm (seeded), and how many confirmed.
        var confirmAnswer: () -> JoinConsentConfirm = { .confirmed }
        var confirmed = 0
        private(set) var model: JoinConsentModel!

        init(truth: Truth) {
            self.truth = truth
            model = JoinConsentModel(services: JoinConsentServices(
                status: { [unowned self] in
                    await boundary()
                    return truth.joined ? JoinStatus(credentialPresent: true, machineId: "m_1") : JoinStatus(credentialPresent: false)
                },
                openLine: { [unowned self] in
                    await boundary()
                    return Line(world: self)
                },
                enabled: { [unowned self] in enabled },
                confirmOwner: { [unowned self] _ in
                    await boundary()
                    let answer = confirmAnswer()
                    if case .confirmed = answer { confirmed += 1 }
                    return answer
                },
                askShown: { [unowned self] in askShown },
                markAskShown: { [unowned self] in askShown = true }))
        }

        func boundary() async {
            guard gating, let op = Current.op else { return }
            let gate = JoinConsentTests.Gate()
            waiting.append((op, gate))
            await gate.wait()
        }

        var record: JoinConsentRecord {
            JoinConsentRecord(screen: truth.screen, control: truth.control, consentRequired: truth.consentRequired)
        }

        /// Every started request is waiting at a boundary or done.
        var quiet: Bool { started.allSatisfy { op in done.contains(op) || waiting.contains { $0.op == op } } }
    }

    @MainActor final class Line: JoinConsentLine {
        unowned let world: World
        init(world: World) { self.world = world }
        var isPerson: Bool { world.truth.person }
        var supportsConsent: Bool { world.truth.capable }
        func read() async -> JoinConsentRecord? {
            let reply = { [world] in world.truth.readFails ? nil : world.record }
            let early = world.early()
            let taken = early ? reply() : nil
            await world.boundary()
            let answer = early ? taken : reply()
            if let op = Current.op { world.reads[op] = answer }
            return answer
        }
        func set(_ surface: JoinConsentSurface, granted: Bool, ticket: JoinConsentGrantTicket?) async -> JoinConsentRecord? {
            // The app's line queues the write here and writes it at the release, as its queue does later:
            // the Labs switch can turn off in between.
            await world.boundary()
            // The real write point: a grant's bytes go out only through its ticket (a stale one sends nothing
            // and the connection closes, so the call answers nil).
            let send = { [world] in world.sends.append(("\(surface.rawValue) \(granted)", world.enabled)) }
            guard ticket.map({ $0.write(send) }) ?? { send(); return true }() else { return nil }
            // acpmux takes a grant and a revoke only from the person's connection.
            guard world.truth.person else { return nil }
            if surface == .screen { world.truth.screen = granted } else { world.truth.control = granted }
            return world.record
        }
        func close() {}
    }

    /// SplitMix64: the same seed, the same run.
    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Tickets served with the Labs switch on, each checked against its own read.
    static var servedChecked = 0

    @Test func everyScheduleKeepsTheInvariants() async {
        Self.servedChecked = 0
        for seed in 0..<5000 {
            guard await Self.run(seed: UInt64(seed)) else { return }
        }
        print("JoinConsentInterleavingTests: \(Self.servedChecked) served tickets checked against their own read")
        #expect(Self.servedChecked > 200, "the schedules serve tickets, so the serve invariant is exercised")
    }

    /// One seeded run; false when it could not finish (the test stops at the first such run).
    private static func run(seed: UInt64) async -> Bool {
        var random = Seeded(state: seed)
        let joined = Bool.random(using: &random)
        // acpmux starts with Screen sharing granted three runs in four, so tickets often find a grant and the
        // serve invariant fires often (it can't pass by never firing).
        let truth = Truth(screen: Int.random(in: 0..<4, using: &random) != 0, control: .random(using: &random), joined: joined,
                          consentRequired: joined ? [true, nil].randomElement(using: &random)! : [false, nil].randomElement(using: &random)!,
                          readFails: Int.random(in: 0..<6, using: &random) == 0,
                          capable: Int.random(in: 0..<8, using: &random) != 0, person: Int.random(in: 0..<8, using: &random) != 0)
        // Tickets are drawn twice as often as each other request, for the same reason.
        let pool = Op.allCases + [.ticketView, .ticketFull]
        let ops = (0..<Int.random(in: 2...5, using: &random)).map { _ in pool.randomElement(using: &random)! }
        let world = World(truth: truth)
        var timing = Seeded(state: seed &+ 0x5EED)
        world.early = { Bool.random(using: &timing) }
        // The device owner confirms most grants, cancels some, and on some Macs can't be asked.
        var owner = Seeded(state: seed &+ 0x0A11)
        world.confirmAnswer = { [JoinConsentConfirm.confirmed, .confirmed, .confirmed, .cancelled, .unavailable].randomElement(using: &owner)! }
        let model = world.model!
        await model.refresh()
        model.refused(JoinConsentRefusal(requester: "Studio", surface: .screen))
        world.gating = true
        let label = "seed \(seed): \(ops), \(truth)"
        var tasks: [Int: Task<String, Never>] = [:]
        var next = 0
        // Writes started with no write in flight (a grant, a revoke, the sheet's Allow): at most one each.
        var admitted = 0
        while true {
            let canStart = next < ops.count
            let choices = world.waiting.count + (canStart ? 1 : 0)
            if choices == 0 { break }
            let pick = Int.random(in: 0..<choices, using: &random)
            let writingBefore = model.writing
            let askBefore = model.ask != nil
            var startedOp: Op?
            if canStart, pick == world.waiting.count {
                let index = next, op = ops[index]
                next += 1
                startedOp = op
                world.started.insert(index)
                tasks[index] = Task {
                    let result = await Current.$op.withValue(index) { await Self.perform(op, index: index, on: world, label: label) }
                    world.done.insert(index)
                    return result
                }
            } else {
                world.waiting.remove(at: pick).gate.open()
            }
            var spins = 0
            while !world.quiet, spins < 10000 {
                await Task.yield()
                spins += 1
            }
            guard world.quiet else {
                Issue.record("a request neither reached a boundary nor finished: \(label)")
                return false
            }
            check(world, label: label)
            if let op = startedOp, !writingBefore, [.grantScreen, .grantControl, .revokeScreen, .revokeControl, .allow].contains(op) {
                admitted += 1
            }
            #expect(world.sends.count <= admitted, "a write sent while another was in flight: \(label)")
            if let op = startedOp {
                checkStart(op, world: world, writingBefore: writingBefore, askBefore: askBefore, label: label)
            }
            for (index, task) in tasks where world.done.contains(index) {
                tasks[index] = nil
                checkDone(ops[index], result: await task.value, world: world, label: label)
            }
            // acpmux changed on its own: once every request under way is done (the folder watch's read
            // among them), the model again allows no more than a read can see, with no further read: a
            // read dropped meanwhile must not have lost the change.
            if world.changedOnItsOwn, world.started.allSatisfy(world.done.contains) {
                world.changedOnItsOwn = false
                check(world, label: label)
            }
        }
        world.gating = false
        #expect(!model.writing, "no write left in flight: \(label)")
        #expect(world.sends.allSatisfy { !$0.write.hasSuffix("true") || $0.enabled }, "a grant sent with Labs off: \(label)")
        #expect(world.sends.filter { $0.write.hasSuffix("true") }.count <= world.confirmed, "a grant sent without the owner's confirm: \(label)")
        if world.enabled {
            await model.refresh()
            #expect(model.permitsMacScreen(control: false) == world.truth.allows(full: false), "converges (View Only): \(label)")
            #expect(model.permitsMacScreen(control: true) == world.truth.allows(full: true), "converges (Full Control): \(label)")
        }
        return true
    }

    private static func perform(_ op: Op, index: Int, on world: World, label: String) async -> String {
        let model = world.model!
        switch op {
        case .read: await model.refresh(); return "read"
        case .ticketView, .ticketFull:
            let full = op == .ticketFull, enabled = world.enabled, start = model.generation
            let served = await model.allowsMacScreen(control: full, requester: "Studio")
            if served, enabled {
                // The strict invariant: nothing serves without a read of its own, at the current
                // generation, that got through and says granted.
                servedChecked += 1
                let read = world.reads[index] ?? nil
                #expect(read.map { $0.consentRequired == false || ($0.screen && (!full || $0.control)) } == true,
                        "served without its own read saying granted: \(label)")
                #expect(model.generation == start + 1, "served on a read that is not the current generation: \(label)")
                #expect(!model.writing, "served with a write in flight: \(label)")
            }
            return served ? "served" : "refused"
        case .grantScreen: return await model.set(.screen, on: true) ?? "set"
        case .grantControl: return await model.set(.control, on: true) ?? "set"
        case .revokeScreen: return await model.set(.screen, on: false) ?? "set"
        case .revokeControl: return await model.set(.control, on: false) ?? "set"
        case .allow: return await model.answer(allow: true) ?? "answered"
        case .deny: return await model.answer(allow: false) ?? "answered"
        case .labsOff:
            world.enabled = false
            await model.featureChanged()
            return "off"
        case .joinFlip, .readFlip, .revokeElsewhere:
            switch op {
            case .joinFlip:
                world.truth.joined.toggle()
                world.truth.consentRequired = world.truth.joined ? true : [false, nil][index % 2]
            case .readFlip: world.truth.readFails.toggle()
            default: world.truth.screen = false
            }
            world.changedOnItsOwn = true
            await model.refresh() // the folder watch's read
            return "changed"
        }
    }

    /// After every step: the model never allows more than a read of acpmux can see.
    private static func check(_ world: World, label: String) {
        guard world.enabled, !world.changedOnItsOwn else { return }
        for full in [false, true] where world.model.permitsMacScreen(control: full) {
            #expect(world.truth.allows(full: full), "allows more than acpmux (full \(full)): \(label)")
        }
    }

    /// Right after a request starts.
    private static func checkStart(_ op: Op, world: World, writingBefore: Bool, askBefore: Bool, label: String) {
        let model = world.model!
        switch op {
        case .revokeScreen where !writingBefore && world.enabled:
            #expect(!model.permitsMacScreen(control: false), "a revoke narrows the moment it starts: \(label)")
        case .revokeControl where !writingBefore && world.enabled:
            #expect(!model.permitsMacScreen(control: true), "a revoke narrows the moment it starts: \(label)")
        case .deny where writingBefore && askBefore:
            #expect(model.ask != nil, "a Deny closed the sheet over a write: \(label)")
        default: break
        }
    }

    /// When a request ends.
    private static func checkDone(_ op: Op, result: String, world: World, label: String) {
        switch op {
        case .grantScreen, .grantControl, .revokeScreen, .revokeControl:
            #expect(result != "set" || world.sends.contains { $0.write.hasSuffix(op == .grantScreen || op == .grantControl ? "true" : "false") },
                    "a write reported set that acpmux never received: \(label)")
        case .ticketView, .ticketFull:
            if result == "served", world.enabled, !world.changedOnItsOwn {
                #expect(world.truth.allows(full: op == .ticketFull) && !world.model.writing, "served without acpmux's grant: \(label)")
            }
        default: break
        }
    }
}
