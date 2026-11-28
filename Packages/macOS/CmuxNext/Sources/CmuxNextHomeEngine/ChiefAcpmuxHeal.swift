public import CmuxNextAgentPane
import CmuxNextHomeModel
import Foundation
import os

/// Heals a Chief chat that cannot reach the Chief home's acpmux because that
/// daemon runs an old version an update replaced (2026-10-18: the NIGHTLY
/// update left daemon 8886 on the deleted binary, and every Chief chat said
/// "acpmux did not start" until a manual restart).
///
/// The heal is the same path a relaunch takes (`HomeBrainHost.start`), run
/// while the app runs: the stale daemon is handed off (`_acpmux/shutdown`; its
/// agent hosts keep running and the next daemon adopts them), the Chief host
/// that ran on it is stopped (or, when it takes that, asked to hand off when its
/// turn ends, so the heal never cuts a Chief turn), and the brain keeper's watch
/// starts the host again, which starts the bundled acpmux. A tab still never starts that
/// daemon itself (cx-ebm.54).
///
/// What follows each handoff answer is `chief_brain.heal_plan` and `chief_brain.heal_finish_step`
/// in cmux-home-rules; this type runs the handoff, the stop, the waits and the ensure in order.
public nonisolated struct ChiefAcpmuxHeal: Sendable {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "home")

    let home: ChiefHome
    let environment: AcpmuxEnvironment
    /// Starts the brain host when none runs (`ChiefBrainKeeper.ensure`), after the stop.
    let ensureHost: @Sendable () async -> Void

    /// - Parameters:
    ///   - home: the Chief home whose acpmux the chat uses.
    ///   - environment: that home's acpmux environment (`ChiefHome.acpmuxHome`).
    ///   - ensureHost: starts the Chief host again when its watch did not.
    public init(home: ChiefHome, environment: AcpmuxEnvironment, ensureHost: @escaping @Sendable () async -> Void) {
        self.home = home
        self.environment = environment
        self.ensureHost = ensureHost
    }

    /// Hands off the stale daemon and restarts the Chief host. Returns whether
    /// it handed one off now; false leaves the daemon running (the Chief host may
    /// have been asked to hand off when its turn ends: then the heal finishes after that).
    @concurrent public func heal() async -> Bool {
        let handoff = AcpmuxChiefHandoff(environment: environment, chiefMuxHome: home.muxHome.path)
        // An update never cuts a Chief turn: a host that takes it hands off when its turn ends,
        // and the heal finishes after it exits. Only an older host is stopped here.
        let home = home
        // The host that took the signal, not one read before it: a host that starts in between
        // would otherwise be stopped mid-turn when the one read earlier is already gone.
        let asked = OSAllocatedUnfairLock<pid_t?>(initialState: nil)
        let action = await handoff.handOffReplaced(waitFor: {
            let pid = ChiefHostStop.askToHandOffWhenIdle(home: home)
            asked.withLock { $0 = pid }
            return pid != nil
        })
        let actionName = switch action {
        case .keep: "keep"
        case .waitForHost: "waitForHost"
        case .handOff: "handOff"
        }
        guard let plan: HealPlan = try? HomeRules.chiefBrain("heal_plan", HealRequest(action: actionName)) else { return false }
        for effect in plan.effects {
            switch effect.kind {
            case "finishAfterTurn":
                let ensureHost = ensureHost
                let host = asked.withLock { $0 }
                // task-owner: one follow-up per stale daemon (the pane heals each pid once); it ends
                // when the host exits, however long its turn runs (one exit source, no timer)
                Task.detached {
                    await Self.finishAfterTurn(
                        hostExited: {
                            guard let host else { return true }
                            return await AgentPaneProcessExit(pid: host).event(within: nil)
                        },
                        handOff: { await handoff.handOffReplaced(waitFor: { false }) == .handOff },
                        stopHost: { await Self.stopHost(home: home) },
                        ensureHost: ensureHost)
                }
            case "stopHost":
                await Self.stopHost(home: home)
            case "ensureHost":
                await ensureHost()
            default:
                Self.logger.error("Chief acpmux heal: unknown effect \(effect.kind, privacy: .public)")
            }
        }
        return plan.healed
    }

    /// After the Chief host that was asked to hand off when idle exits: hands the replaced
    /// daemon off here, not through `HomeBrainHost.start` (its handoff runs once per Chief
    /// home per app run, so a second update in one run would leave the daemon in place), stops
    /// a host the brain watch started on it meanwhile, and starts the host again, which the
    /// brain watch may not do (no watch, or its restart limit). A host that never exits leaves
    /// everything as it is.
    static func finishAfterTurn(hostExited: () async -> Bool, handOff: () async -> Bool,
                                stopHost: () async -> Void, ensureHost: () async -> Void) async {
        var phase: String?
        var event: FinishEvent? = FinishEvent(kind: "hostExit", exited: await hostExited())
        while let next = event {
            guard let reply: FinishReply = try? HomeRules.chiefBrain("heal_finish_step", FinishRequest(phase: phase, event: next))
            else { return }
            phase = reply.phase
            event = nil
            for effect in reply.effects {
                switch effect.kind {
                case "handOff":
                    event = FinishEvent(kind: "handOff", handedOff: await handOff())
                case "stopHost":
                    await stopHost()
                    event = FinishEvent(kind: "done")
                case "ensureHost":
                    await ensureHost()
                    event = FinishEvent(kind: "done")
                case "log":
                    let message = effect.message ?? ""
                    if effect.error == true {
                        logger.error("\(message, privacy: .public)")
                    } else {
                        logger.info("\(message, privacy: .public)")
                    }
                default:
                    logger.error("Chief acpmux heal: unknown effect \(effect.kind, privacy: .public)")
                }
            }
        }
    }

    /// Stops the Chief host that ran on a daemon just handed off, and waits for it to exit.
    @concurrent static func stopHost(home: ChiefHome) async {
        guard let pid = await ChiefHostStop.stop(home: home) else { return }
        logger.info("Chief host \(pid) stopped after its acpmux handoff; the brain watch starts it again")
        _ = await AgentPaneProcessExit(pid: pid).event(within: .seconds(15))
    }
}

private nonisolated struct HealRequest: Encodable {
    var action: String
}

/// `chief_brain::heal::HealReply`; effects flat, `kind` names the case.
private nonisolated struct HealPlan: Decodable {
    nonisolated struct Effect: Decodable {
        var kind: String
    }

    var effects: [Effect]
    var healed: Bool
}

private nonisolated struct FinishEvent: Encodable {
    var kind: String
    var exited: Bool?
    var handedOff: Bool?
}

private nonisolated struct FinishRequest: Encodable {
    var phase: String?
    var event: FinishEvent
}

/// `chief_brain::heal::FinishReply`; effects flat.
private nonisolated struct FinishReply: Decodable {
    nonisolated struct Effect: Decodable {
        var kind: String
        var error: Bool?
        var message: String?
    }

    var phase: String
    var effects: [Effect]
}
