import CmuxChief
import CmuxHomeCore
import Foundation

/// The brain the owner talks to while the user's Chief settings change.
///
/// `ChiefConversationOwner` takes one brain for its lifetime; the app swaps
/// the real one behind this actor when `chief.harness`, `chief.model` or
/// `chief.effort` change. A turn keeps the brain it started on (its stop and
/// approvals go there); a replaced brain shuts down once its last turn ends.
actor ChiefBrainSwitch {
    /// One installed brain and its live turns.
    private final class Slot: Sendable {
        let brain: any ChiefBrain
        let settings: ChiefEngineSettings
        init(brain: any ChiefBrain, settings: ChiefEngineSettings) {
            self.brain = brain
            self.settings = settings
        }
    }

    private var current: Slot
    /// Live turns per slot.
    private var active: [ObjectIdentifier: Int] = [:]
    /// Replaced slots that still run a turn.
    private var retired: [ObjectIdentifier: Slot] = [:]
    /// The slot of each conversation's running (or last) turn.
    private var turnSlot: [ConversationID: Slot] = [:]
    /// The harness of each conversation's last turn, so a session id is never
    /// resumed on another harness.
    private var lastHarness: [ConversationID: String] = [:]
    /// Turns handed out by ``ChiefSwitchingBrain/run(_:)`` that have not
    /// reached a brain yet; a Stop in that window cancels them here.
    nonisolated let pendingTurns = ChiefPendingTurns()

    init(brain: any ChiefBrain, settings: ChiefEngineSettings) {
        current = Slot(brain: brain, settings: settings)
    }

    /// The settings of the installed brain.
    var settings: ChiefEngineSettings { current.settings }

    /// Installs `brain` for the next turns.
    func replace(with brain: any ChiefBrain, settings: ChiefEngineSettings) async {
        let old = current
        current = Slot(brain: brain, settings: settings)
        if active[ObjectIdentifier(old), default: 0] > 0 {
            retired[ObjectIdentifier(old)] = old
        } else {
            await old.brain.shutdown()
        }
    }

    /// Starts turn `token` on the installed brain, nil when it was stopped first.
    ///
    /// The inner brain's `run` is called here, on this actor, so it has
    /// registered the turn before ``brain(for:)`` can route a Stop to it.
    fileprivate func begin(_ request: ChiefTurnRequest, token: UUID)
        -> (events: AsyncThrowingStream<ChiefTurnEvent, any Error>, slot: ObjectIdentifier)? {
        guard pendingTurns.claim(token) else { return nil }
        let slot = current
        var request = request
        // A Claude session id means nothing to Codex (and back).
        if let previous = lastHarness[request.conversation], previous != slot.settings.resolvedHarness.rawValue {
            request.resumeSession = nil
        }
        lastHarness[request.conversation] = slot.settings.resolvedHarness.rawValue
        turnSlot[request.conversation] = slot
        active[ObjectIdentifier(slot), default: 0] += 1
        return (slot.brain.run(request), ObjectIdentifier(slot))
    }

    /// A turn on `slot` ended.
    fileprivate func end(_ slot: ObjectIdentifier) async {
        let count = max(0, active[slot, default: 0] - 1)
        active[slot] = count == 0 ? nil : count
        guard count == 0, let old = retired.removeValue(forKey: slot) else { return }
        await old.brain.shutdown()
    }

    /// The brain that runs (or last ran) `conversation`'s turn.
    fileprivate func brain(for conversation: ConversationID) -> any ChiefBrain {
        (turnSlot[conversation] ?? current).brain
    }

    /// Shuts every brain down (app quit).
    func shutdownAll() async {
        let all = [current] + Array(retired.values)
        retired.removeAll()
        for slot in all { await slot.brain.shutdown() }
    }
}

/// The ``ChiefBrain`` handed to the owner: forwards each call to the brain
/// installed in a ``ChiefBrainSwitch``.
struct ChiefSwitchingBrain: ChiefBrain {
    let switcher: ChiefBrainSwitch

    func run(_ request: ChiefTurnRequest) -> AsyncThrowingStream<ChiefTurnEvent, any Error> {
        let switcher = switcher
        let token = UUID()
        // Registered before the stream is returned, so a Stop that beats `begin` still cancels the turn.
        switcher.pendingTurns.register(token, conversation: request.conversation)
        return AsyncThrowingStream { continuation in
            // task-owner: one turn; cancelled by the stream's termination (Stop), ends with the inner stream
            let task = Task {
                guard let started = await switcher.begin(request, token: token) else {
                    continuation.finish()
                    return
                }
                do {
                    for try await event in started.events {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                await switcher.end(started.slot)
            }
            continuation.onTermination = { _ in
                switcher.pendingTurns.stop(token)
                task.cancel()
            }
        }
    }

    func respond(toApproval id: String, choice: String, conversation: ConversationID) async {
        await switcher.brain(for: conversation).respond(toApproval: id, choice: choice, conversation: conversation)
    }

    func interrupt(conversation: ConversationID) async {
        // A turn still waiting for `begin` never starts; one past it is routed below.
        switcher.pendingTurns.stop(conversation: conversation)
        await switcher.brain(for: conversation).interrupt(conversation: conversation)
    }

    func shutdown() async {
        await switcher.shutdownAll()
    }
}
