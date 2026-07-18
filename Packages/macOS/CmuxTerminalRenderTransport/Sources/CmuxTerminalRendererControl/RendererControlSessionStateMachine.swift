internal import Foundation

/// Validates cross-direction ordering and exact presentation ownership for one worker.
public struct RendererControlSessionStateMachine: Sendable {
    /// Maximum detached presentation lifetimes retained for exact late releases.
    public static let maximumRetiredPresentations = 8_192

    /// Whether shutdown, fatal failure, or a protocol violation ended the session.
    public var isTerminal: Bool {
        phase == .terminal || phase == .failed
    }

    /// Number of presentation lifetimes currently attached to the worker.
    public var presentationCount: Int {
        presentations.count
    }

    private var phase = RendererControlSessionPhase.awaitingBootstrap
    private var bootstrap: RendererBootstrap?
    private var presentations: [UUID: RendererPresentationAttachment] = [:]
    private var retiredPresentations: [PresentationLifetime: RendererPresentationAttachment] = [:]
    private var retiredPresentationOrder: [PresentationLifetime] = []
    private var retiredPresentationOrderHead = 0
    private var highestPresentationGenerations: [UUID: UInt64] = [:]
    private var lastSceneSequences: [UUID: (canonical: UInt64, presentation: UInt64)] = [:]
    private var readyPresentations: Set<UUID> = []
    private var pendingRemovalAcknowledgements: [
        PresentationLifetime: PendingRemovalAcknowledgement
    ] = [:]
    private var nextDaemonSequence: UInt64? = 1
    private var nextWorkerSequence: UInt64? = 1

    /// Creates a state machine awaiting daemon bootstrap sequence one.
    public init() {}

    private struct PresentationLifetime: Hashable, Sendable {
        let id: UUID
        let generation: UInt64
    }

    private struct PendingRemovalAcknowledgement: Sendable {
        let removal: RendererPresentationRemoval
        var acknowledgementsDue: UInt64
        var retainedForLateRelease: Bool
    }

    /// Accepts one decoded envelope or permanently fails the session.
    ///
    /// - Parameter envelope: The next envelope in either authenticated direction.
    /// - Throws: ``RendererControlError`` for a sequence, lifecycle, or ownership violation.
    public mutating func accept(_ envelope: RendererControlEnvelope) throws {
        guard !isTerminal else {
            throw RendererControlError.invalidTransition
        }
        do {
            try validateSequence(envelope)
            try transition(envelope)
            advanceSequence(envelope.direction)
        } catch {
            phase = .failed
            presentations.removeAll(keepingCapacity: false)
            retiredPresentations.removeAll(keepingCapacity: false)
            retiredPresentationOrder.removeAll(keepingCapacity: false)
            retiredPresentationOrderHead = 0
            highestPresentationGenerations.removeAll(keepingCapacity: false)
            lastSceneSequences.removeAll(keepingCapacity: false)
            readyPresentations.removeAll(keepingCapacity: false)
            pendingRemovalAcknowledgements.removeAll(keepingCapacity: false)
            throw error
        }
    }

    private mutating func validateSequence(_ envelope: RendererControlEnvelope) throws {
        let expected = switch envelope.direction {
        case .daemonToWorker:
            nextDaemonSequence
        case .workerToDaemon:
            nextWorkerSequence
        }
        guard let expected else {
            throw RendererControlError.sequenceExhausted
        }
        guard envelope.sequence == expected else {
            throw RendererControlError.invalidSequence(
                expected: expected,
                actual: envelope.sequence
            )
        }
    }

    private mutating func advanceSequence(_ direction: RendererControlDirection) {
        switch direction {
        case .daemonToWorker:
            if let value = nextDaemonSequence {
                nextDaemonSequence = value == UInt64.max ? nil : value + 1
            }
        case .workerToDaemon:
            if let value = nextWorkerSequence {
                nextWorkerSequence = value == UInt64.max ? nil : value + 1
            }
        }
    }

    private mutating func transition(_ envelope: RendererControlEnvelope) throws {
        switch phase {
        case .awaitingBootstrap:
            guard case let .bootstrap(value) = envelope.message,
                  envelope.direction == .daemonToWorker else {
                throw RendererControlError.invalidTransition
            }
            bootstrap = value
            phase = .awaitingReady

        case .awaitingReady:
            switch envelope.message {
            case .ready:
                guard envelope.direction == .workerToDaemon else {
                    throw RendererControlError.invalidTransition
                }
                phase = .active
            case .shutdown:
                phase = .terminal
            case .fatal:
                phase = .terminal
            default:
                throw RendererControlError.invalidTransition
            }

        case .active:
            try transitionActive(envelope.message)

        case .terminal, .failed:
            throw RendererControlError.invalidTransition
        }
    }

    private mutating func transitionActive(_ message: RendererControlMessage) throws {
        switch message {
        case .bootstrap, .ready:
            throw RendererControlError.invalidTransition

        case let .upsertPresentation(value):
            if let attached = presentations[value.presentationID] {
                guard attached.terminalID == value.terminalID,
                      attached.terminalEpoch == value.terminalEpoch else {
                    throw RendererControlError.invalidTransition
                }
                retire(attached)
            }
            if let previousGeneration = highestPresentationGenerations[value.presentationID] {
                guard value.presentationGeneration > previousGeneration else {
                    throw RendererControlError.invalidTransition
                }
            }
            presentations[value.presentationID] = value
            highestPresentationGenerations[value.presentationID] = value.presentationGeneration
            lastSceneSequences.removeValue(forKey: value.presentationID)
            readyPresentations.remove(value.presentationID)

        case let .removePresentation(value):
            let lifetime = PresentationLifetime(
                id: value.presentationID,
                generation: value.presentationGeneration
            )
            if let attached = presentations[value.presentationID] {
                guard matches(
                    attached,
                    terminalID: value.terminalID,
                    terminalEpoch: value.terminalEpoch,
                    presentationGeneration: value.presentationGeneration
                ) else {
                    throw RendererControlError.invalidTransition
                }
                retire(attached)
                presentations.removeValue(forKey: value.presentationID)
                lastSceneSequences.removeValue(forKey: value.presentationID)
                readyPresentations.remove(value.presentationID)
                pendingRemovalAcknowledgements[lifetime] = PendingRemovalAcknowledgement(
                    removal: value,
                    acknowledgementsDue: 1,
                    retainedForLateRelease: true
                )
            } else {
                guard var pending = pendingRemovalAcknowledgements[lifetime],
                      pending.removal == value,
                      pending.acknowledgementsDue < UInt64.max else {
                    throw RendererControlError.invalidTransition
                }
                pending.acknowledgementsDue += 1
                pendingRemovalAcknowledgements[lifetime] = pending
            }

        case let .semanticScene(value):
            guard let attached = presentations[value.presentationID],
                  matches(
                    attached,
                    terminalID: value.terminalID,
                    terminalEpoch: value.terminalEpoch,
                    presentationGeneration: value.presentationGeneration
                  ) else {
                throw RendererControlError.invalidTransition
            }
            if let previous = lastSceneSequences[value.presentationID] {
                guard value.canonicalSequence >= previous.canonical,
                      value.presentationSequence >= previous.presentation else {
                    throw RendererControlError.invalidTransition
                }
            }
            lastSceneSequences[value.presentationID] = (
                canonical: value.canonicalSequence,
                presentation: value.presentationSequence
            )

        case let .frameRelease(value):
            guard let bootstrap,
                  value.daemonInstanceID == bootstrap.daemonInstanceID,
                  value.rendererEpoch == bootstrap.rendererEpoch,
                  let attached = releaseAttachment(for: value),
                  matches(
                    attached,
                    terminalID: value.terminalID,
                    terminalEpoch: value.terminalEpoch,
                    presentationGeneration: value.presentationGeneration
                  ) else {
                throw RendererControlError.invalidTransition
            }

        case let .needsFullScene(value):
            guard let attached = presentations[value.presentationID],
                  matches(
                    attached,
                    terminalID: value.terminalID,
                    terminalEpoch: value.terminalEpoch,
                    presentationGeneration: value.presentationGeneration
                  ) else {
                throw RendererControlError.invalidTransition
            }

        case let .presentationReady(value):
            guard let attached = presentations[value.presentationID],
                  matches(
                    attached,
                    terminalID: value.terminalID,
                    terminalEpoch: value.terminalEpoch,
                    presentationGeneration: value.presentationGeneration
                  ),
                  let scene = lastSceneSequences[value.presentationID],
                  scene.canonical == value.canonicalSequence,
                  scene.presentation == value.presentationSequence,
                  !readyPresentations.contains(value.presentationID) else {
                throw RendererControlError.invalidTransition
            }
            readyPresentations.insert(value.presentationID)

        case let .presentationRemoved(value):
            let lifetime = PresentationLifetime(
                id: value.presentationID,
                generation: value.presentationGeneration
            )
            guard var pending = pendingRemovalAcknowledgements[lifetime],
                  pending.acknowledgementsDue > 0,
                  pending.removal.terminalID == value.terminalID,
                  pending.removal.terminalEpoch == value.terminalEpoch else {
                throw RendererControlError.invalidTransition
            }
            pending.acknowledgementsDue -= 1
            if pending.acknowledgementsDue == 0, !pending.retainedForLateRelease {
                pendingRemovalAcknowledgements.removeValue(forKey: lifetime)
            } else {
                pendingRemovalAcknowledgements[lifetime] = pending
            }

        case .shutdown, .fatal:
            presentations.removeAll(keepingCapacity: false)
            retiredPresentations.removeAll(keepingCapacity: false)
            retiredPresentationOrder.removeAll(keepingCapacity: false)
            retiredPresentationOrderHead = 0
            highestPresentationGenerations.removeAll(keepingCapacity: false)
            lastSceneSequences.removeAll(keepingCapacity: false)
            readyPresentations.removeAll(keepingCapacity: false)
            pendingRemovalAcknowledgements.removeAll(keepingCapacity: false)
            phase = .terminal
        }
    }

    private mutating func retire(_ attachment: RendererPresentationAttachment) {
        let lifetime = PresentationLifetime(
            id: attachment.presentationID,
            generation: attachment.presentationGeneration
        )
        guard retiredPresentations[lifetime] == nil else { return }
        retiredPresentations[lifetime] = attachment
        retiredPresentationOrder.append(lifetime)
        if retiredPresentations.count > Self.maximumRetiredPresentations {
            let oldest = retiredPresentationOrder[retiredPresentationOrderHead]
            retiredPresentationOrderHead += 1
            retiredPresentations.removeValue(forKey: oldest)
            if var pending = pendingRemovalAcknowledgements[oldest] {
                pending.retainedForLateRelease = false
                if pending.acknowledgementsDue == 0 {
                    pendingRemovalAcknowledgements.removeValue(forKey: oldest)
                } else {
                    pendingRemovalAcknowledgements[oldest] = pending
                }
            }
        }
        if retiredPresentationOrderHead >= Self.maximumRetiredPresentations,
           retiredPresentationOrderHead * 2 >= retiredPresentationOrder.count {
            retiredPresentationOrder.removeFirst(retiredPresentationOrderHead)
            retiredPresentationOrderHead = 0
        }
    }

    private func releaseAttachment(
        for release: RendererControlFrameRelease
    ) -> RendererPresentationAttachment? {
        if let current = presentations[release.presentationID],
           current.presentationGeneration == release.presentationGeneration {
            return current
        }
        return retiredPresentations[PresentationLifetime(
            id: release.presentationID,
            generation: release.presentationGeneration
        )]
    }

    private func matches(
        _ attached: RendererPresentationAttachment,
        terminalID: UUID,
        terminalEpoch: UInt64,
        presentationGeneration: UInt64
    ) -> Bool {
        attached.terminalID == terminalID
            && attached.terminalEpoch == terminalEpoch
            && attached.presentationGeneration == presentationGeneration
    }
}
