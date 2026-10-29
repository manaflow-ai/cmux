import CmuxNextServer
import Foundation
import Testing
@testable import CmuxNextApp

/// The consent state machine under a deterministic scheduler. Each run picks two to four requests (with
/// repeats) from reads, Mac Screen tickets (View Only and Full Control), grants and revokes of either
/// surface, the sheet's Allow and Deny, and the Labs switch turning off, over a random acpmux state
/// (granted or not, joined or not, reads failing or not). Every acpmux boundary a request reaches (the
/// join status, opening the line, the record read, the write) waits until the scheduler releases it, and
/// the scheduler interleaves starts and releases in a seeded random order. A reply is taken at its
/// release, so a reply released before a write is the stale one it would be. After every step, once each
/// started request is again waiting or done, the invariants are checked:
/// - What the model allows Mac Screen is never more than acpmux's record grants (no stale grant, a revoke
///   narrows the moment it starts, an unread record allows nothing).
/// - A ticket serves only when acpmux allows its scope and no write is in flight; otherwise it is refused.
/// - One write at a time: a second one is refused as busy; a grant is never sent with the Labs switch off.
/// - A press during a write does nothing: a Deny never closes the sheet over it, an Allow never writes.
/// - When all is done, no write is in flight and one more read brings the model to what acpmux holds.
@MainActor @Suite(.serialized) struct JoinConsentInterleavingTests {
    enum Op: CaseIterable {
        case read, ticketView, ticketFull, grantScreen, grantControl, revokeScreen, revokeControl, allow, deny, labsOff
    }

    /// What acpmux holds.
    struct Truth {
        var screen: Bool
        var control: Bool
        var joined: Bool
        var consentRequired: Bool?
        var readFails: Bool

        /// What acpmux's record grants, whether or not a read of it gets through.
        func holds(full: Bool) -> Bool {
            consentRequired == false || (screen && (!full || control))
        }

        /// What a ticket may serve: a grant its own read can see.
        func allows(full: Bool) -> Bool { !readFails && holds(full: full) }
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
        var isPerson: Bool { true }
        var supportsConsent: Bool { true }
        func read() async -> JoinConsentRecord? {
            await world.boundary()
            return world.truth.readFails ? nil : world.record
        }
        func set(_ surface: JoinConsentSurface, granted: Bool) async -> JoinConsentRecord? {
            // The app sends the write here; acpmux takes it at the release.
            world.sends.append(("\(surface.rawValue) \(granted)", world.enabled))
            await world.boundary()
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

    @Test func everyScheduleKeepsTheInvariants() async {
        for seed in 0..<1500 {
            guard await Self.run(seed: UInt64(seed)) else { return }
        }
    }

    /// One seeded run; false when it could not finish (the test stops at the first such run).
    private static func run(seed: UInt64) async -> Bool {
        var random = Seeded(state: seed)
        let joined = Bool.random(using: &random)
        let truth = Truth(screen: .random(using: &random), control: .random(using: &random), joined: joined,
                          consentRequired: joined ? [true, nil].randomElement(using: &random)! : [false, nil].randomElement(using: &random)!,
                          readFails: Int.random(in: 0..<6, using: &random) == 0)
        let ops = (0..<Int.random(in: 2...4, using: &random)).map { _ in Op.allCases.randomElement(using: &random)! }
        let world = World(truth: truth)
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
                    let result = await Current.$op.withValue(index) { await Self.perform(op, on: world) }
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
        }
        world.gating = false
        #expect(!model.writing, "no write left in flight: \(label)")
        #expect(world.sends.allSatisfy { !$0.write.hasSuffix("true") || $0.enabled }, "a grant sent with Labs off: \(label)")
        if world.enabled {
            await model.refresh()
            #expect(model.permitsMacScreen(control: false) == world.truth.allows(full: false), "converges (View Only): \(label)")
            #expect(model.permitsMacScreen(control: true) == world.truth.allows(full: true), "converges (Full Control): \(label)")
        }
        return true
    }

    private static func perform(_ op: Op, on world: World) async -> String {
        let model = world.model!
        switch op {
        case .read: await model.refresh(); return "read"
        case .ticketView: return await model.allowsMacScreen(control: false, requester: "Studio") ? "served" : "refused"
        case .ticketFull: return await model.allowsMacScreen(control: true, requester: "Studio") ? "served" : "refused"
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
        }
    }

    /// After every step: the model never allows more than acpmux's record grants.
    private static func check(_ world: World, label: String) {
        guard world.enabled else { return }
        for full in [false, true] where world.model.permitsMacScreen(control: full) {
            #expect(world.truth.holds(full: full), "allows more than acpmux (full \(full)): \(label)")
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
            if result == "served", world.enabled {
                #expect(world.truth.allows(full: op == .ticketFull) && !world.model.writing, "served without acpmux's grant: \(label)")
            }
        default: break
        }
    }
}
