import Foundation
import Testing
@testable import CmuxNextDesign

/// Exhaustive model check of the hover card reducer (dogfood 2026-10-01:
/// "need to formally verify that only one hover card can appear at a
/// time"). Universe: 2 windows, 3 targets, the current and a stale timer
/// token, every dismissal kind that differs, both suppressions, removal
/// and pin. The "world" is the one card and the one timer, driven only by
/// the effects, so the check covers the effects as well as the state.
/// Nonisolated and serialized: the exploration is seconds to minutes of CPU,
/// which on the main actor (this target's default isolation) stalls every
/// main-actor test in the process past its time limit; serialized keeps the
/// mutant cases from filling the cooperative pool at once.
@Suite(.serialized) nonisolated struct HoverCardModelCheckTests {
    struct World: Hashable {
        var visible: HoverTargetID?
        var armed: Int?
    }

    static let targets = [
        HoverTarget(id: HoverTargetID("tab:a"), window: 1, delay: .milliseconds(300)),
        HoverTarget(id: HoverTargetID("tab:b"), window: 1, delay: .milliseconds(800)),
        // The workspace card shows on its first hit (no delay).
        HoverTarget(id: HoverTargetID("ws:c"), window: 2, delay: .zero),
    ]

    /// Symbolic events; deadlines resolve against the state they hit.
    enum Step: Hashable {
        case hit(Int?, moved: Bool)
        case deadlineCurrent, deadlineStale
        case dismiss(HoverDismissal)
        case suppress(HoverSuppression), unsuppress(HoverSuppression)
        case removed(Int)
        case pin(Int)
    }

    static let alphabet: [Step] = {
        var steps: [Step] = [.hit(nil, moved: true), .hit(nil, moved: false)]
        for i in targets.indices { steps += [.hit(i, moved: true), .hit(i, moved: false)] }
        steps += [.deadlineCurrent, .deadlineStale, .dismiss(.keyDown), .dismiss(.appDeactivated),
                  .suppress(.drag), .unsuppress(.drag), .suppress(.scroll), .unsuppress(.scroll),
                  .removed(0), .removed(2), .pin(1)]
        return steps
    }()

    /// A step's concrete event in `machine`'s state.
    static func event(_ step: Step, _ machine: HoverCardMachine) -> HoverCardEvent {
        switch step {
        case .hit(let index, let moved): .hit(index.map { targets[$0] }, moved: moved)
        // The armed token, else the newest issued one (already stale).
        case .deadlineCurrent: .deadline(token: machine.armedToken ?? machine.nextToken - 1)
        // A token issued before the current one: always stale.
        case .deadlineStale: .deadline(token: (machine.armedToken ?? machine.nextToken) - 1)
        case .dismiss(let reason): .dismiss(reason)
        case .suppress(let reason): .suppress(reason)
        case .unsuppress(let reason): .unsuppress(reason)
        case .removed(let index): .targetRemoved(targets[index].id)
        case .pin(let index): .pin(targets[index])
        }
    }

    /// Delivers `event` to the world (a firing timer is spent) and applies
    /// the reducer's effects.
    static func apply(_ effects: [HoverCardEffect], to world: inout World, for event: HoverCardEvent? = nil) {
        if case .deadline(let token)? = event, token == world.armed { world.armed = nil }
        for effect in effects {
            switch effect {
            case .schedule(let token, _): world.armed = token
            case .cancelTimer: world.armed = nil
            case .show(let target, _): world.visible = target.id
            case .hide: world.visible = nil
            }
        }
    }

    /// The invariants after one step; returns the violated ones.
    static func violations(before: HoverCardMachine, event: HoverCardEvent, after: HoverCardMachine,
                           effects: [HoverCardEffect], world: World) -> [String] {
        var bad: [String] = []
        // I1: the card and the timer are what the state says (at most one of each, app-wide).
        if world.visible != after.shownTarget?.id { bad.append("I1 card \(String(describing: world.visible)) vs state \(String(describing: after.shownTarget?.id))") }
        if world.armed != after.armedToken { bad.append("I1 timer \(String(describing: world.armed)) vs state \(String(describing: after.armedToken))") }
        // I2: a hover card (not pinned) is for what the last hit test found under the pointer.
        if case .shown(let target) = after.phase, after.lastHit?.id != target.id { bad.append("I2 shown \(target.id) not under pointer") }
        // I3: a stale deadline changes nothing.
        if case .deadline(let token) = event, token != before.armedToken, after != before || !effects.isEmpty { bad.append("I3 stale token \(token) acted") }
        // I4: a removed target has no card.
        if case .targetRemoved(let id) = event, after.activeTarget?.id == id || world.visible == id { bad.append("I4 removed \(id) still active") }
        // I5: a dismissal or suppression ends in idle with no card and no timer.
        switch event {
        case .dismiss, .suppress:
            if after.phase != .idle || world.visible != nil || world.armed != nil { bad.append("I5 not idle after \(event)") }
        default: break
        }
        // I6: no card is pending, shown or in grace while suppressed.
        if !after.suppressions.isEmpty, after.phase != .idle { bad.append("I6 active while suppressed") }
        // I7: every timer token is used once (tokens only grow).
        if after.nextToken < before.nextToken { bad.append("I7 token reuse") }
        // I9: content moving under a still pointer never takes a pinned card.
        if case .hit(_, false) = event, case .pinned(let pinned, _) = before.phase, after.shownTarget?.id != pinned.id {
            bad.append("I9 a still pointer took the pinned card of \(pinned.id)")
        }
        // I10: a new target arriving under a still pointer gets the normal
        // path (pending, or at once after a card), and keeps it while it stays.
        if case .hit(let target?, false) = event, before.suppressions.isEmpty {
            let isPinned = if case .pinned = before.phase { true } else { false }
            if !isPinned, target.id != before.lastHit?.id, after.activeTarget?.id != target.id {
                bad.append("I10 new target \(target.id) under a still pointer got no card")
            }
            if case .pending(let pending, _) = before.phase, pending.id == target.id, after.activeTarget?.id != target.id {
                bad.append("I10 pending \(target.id) lost on a repeated still hit")
            }
        }
        // I8: never idle with the pointer resting on a target unless a
        // dismissal made it quiet or a suppression lasts (no lost card).
        if after.phase == .idle, after.lastHit != nil, !after.quiet, after.suppressions.isEmpty {
            bad.append("I8 idle with the pointer resting on \(after.lastHit!.id)")
        }
        return bad
    }

    /// The state with tokens made relative to the next one, so the
    /// reachable set is finite.
    struct Key: Hashable {
        var phase: String
        var suppressions: Set<HoverSuppression>
        var lastHit: HoverTargetID?
        var quiet: Bool
        var world: String
    }

    static func key(_ m: HoverCardMachine, _ w: World) -> Key {
        func rel(_ token: Int?) -> String { token.map { "\(m.nextToken - $0)" } ?? "-" }
        let phase: String = switch m.phase {
        case .idle: "idle"
        case .pending(let t, let token): "pending \(t.id) \(rel(token))"
        case .shown(let t): "shown \(t.id)"
        case .pinned(let t, let token): "pinned \(t.id) \(rel(token))"
        case .leaving(let t, let token): "leaving \(t.id) \(rel(token))"
        case .grace(let token): "grace \(rel(token))"
        }
        return Key(phase: phase, suppressions: m.suppressions, lastHit: m.lastHit?.id, quiet: m.quiet,
                   world: "\(w.visible?.rawValue ?? "-") \(rel(w.armed))")
    }

    /// Every reachable state, every transition (breadth first).
    @Test func everyReachableStateKeepsTheInvariants() {
        var frontier = [(HoverCardMachine(), World())]
        var seen: Set<Key> = [Self.key(HoverCardMachine(), World())]
        var transitions = 0
        var failures: [String] = []
        while let (machine, world) = frontier.popLast() {
            for step in Self.alphabet {
                var next = machine
                var nextWorld = world
                let event = Self.event(step, machine)
                let effects = next.reduce(event)
                Self.apply(effects, to: &nextWorld, for: event)
                transitions += 1
                let bad = Self.violations(before: machine, event: event, after: next, effects: effects, world: nextWorld)
                if !bad.isEmpty, failures.count < 5 { failures.append("\(Self.key(machine, world)) --\(step)--> \(bad)") }
                if seen.insert(Self.key(next, nextWorld)).inserted { frontier.append((next, nextWorld)) }
            }
        }
        print("hovercard-model-check: \(seen.count) states, \(transitions) transitions, alphabet \(Self.alphabet.count)")
        #expect(failures.isEmpty, "\(failures)")
        #expect(seen.count >= 40, "the universe reaches every phase with every suppression and hit")
    }

    /// Liveness on the reachable set: from every state without a
    /// suppression, a pointer that moves onto a target and rests until its
    /// timer fires gets that target's card.
    @Test func aRestingPointerAlwaysGetsItsCard() {
        var frontier = [(HoverCardMachine(), World())]
        var seen: Set<Key> = [Self.key(HoverCardMachine(), World())]
        var checked = 0
        while let (machine, world) = frontier.popLast() {
            if machine.suppressions.isEmpty {
                for target in Self.targets {
                    var m = machine
                    var w = world
                    Self.apply(m.reduce(.hit(target, moved: true)), to: &w)
                    if let token = m.armedToken { Self.apply(m.reduce(.deadline(token: token)), to: &w, for: .deadline(token: token)) }
                    #expect(m.shownTarget?.id == target.id && w.visible == target.id, "from \(Self.key(machine, world))")
                    checked += 1
                }
            }
            for step in Self.alphabet {
                var next = machine
                var w = world
                let event = Self.event(step, machine)
                Self.apply(next.reduce(event), to: &w, for: event)
                if seen.insert(Self.key(next, w)).inserted { frontier.append((next, w)) }
            }
        }
        #expect(checked > 0)
    }

    /// Every event sequence up to `depth` (no state merging), invariants
    /// after every step. HOVERCARD_MODEL_DEPTH raises the depth.
    @Test func everySequenceUpToTheDepthKeepsTheInvariants() {
        let depth = Int(ProcessInfo.processInfo.environment["HOVERCARD_MODEL_DEPTH"] ?? "") ?? 5
        var sequences = 0
        var steps = 0
        var failure: String?
        func explore(_ machine: HoverCardMachine, _ world: World, _ remaining: Int, _ path: [Step]) {
            guard remaining > 0 else {
                sequences += 1
                return
            }
            for step in Self.alphabet {
                var next = machine
                var w = world
                let event = Self.event(step, machine)
                let effects = next.reduce(event)
                Self.apply(effects, to: &w, for: event)
                steps += 1
                if failure == nil {
                    let bad = Self.violations(before: machine, event: event, after: next, effects: effects, world: w)
                    if !bad.isEmpty { failure = "\(path + [step]): \(bad)" }
                }
                explore(next, w, remaining - 1, path + [step])
            }
        }
        explore(HoverCardMachine(), World(), depth, [])
        print("hovercard-model-check: depth \(depth), \(sequences) sequences, \(steps) steps")
        #expect(failure == nil, "\(failure ?? "")")
    }
}
