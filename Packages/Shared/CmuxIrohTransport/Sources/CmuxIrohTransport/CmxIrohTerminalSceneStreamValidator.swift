public import Foundation

/// Enforces one configuration, a full bootstrap, and contiguous presentation scenes.
public struct CmxIrohTerminalSceneStreamValidator: Sendable {
    /// Fail-closed reasons that require a fresh presentation generation.
    public enum ValidationError: Error, Equatable, Sendable {
        case missingConfiguration
        case unexpectedConfiguration
        case missingFullScene
        case missingAccessibility
        case identityMismatch
        case presentationSequenceGap(expected: UInt64, actual: UInt64)
        case contentSequenceRegression(previous: UInt64, actual: UInt64)
        case accessibilitySceneMismatch
        case presentationSequenceExhausted
    }

    private struct PendingAccessibility: Sendable {
        let configuration: CmxIrohTerminalSceneConfiguration
        let contentSequence: UInt64
        let presentationSequence: UInt64
    }

    private enum Phase: Sendable {
        case awaitingConfiguration
        case awaitingFull(CmxIrohTerminalSceneConfiguration)
        case awaitingAccessibility(PendingAccessibility)
        case active(CmxIrohTerminalSceneConfiguration)
    }

    private let presentationID: UUID
    private let presentationGeneration: UInt64
    private var phase: Phase = .awaitingConfiguration
    private var nextPresentationSequence: UInt64 = 1
    private var lastContentSequence: UInt64?

    public init(
        presentationID: UUID,
        presentationGeneration: UInt64
    ) {
        self.presentationID = presentationID
        self.presentationGeneration = presentationGeneration
    }

    /// Whether a full scene has established the renderer's decode cache.
    public var isReady: Bool {
        if case .active = phase { true } else { false }
    }

    /// Accepts one record or throws before it can mutate renderer state.
    public mutating func accept(
        _ envelope: CmxIrohTerminalSceneEnvelope
    ) throws {
        switch (phase, envelope) {
        case (.awaitingConfiguration, let .configuration(configuration)):
            guard configuration.presentationID == presentationID,
                  configuration.presentationGeneration == presentationGeneration else {
                throw ValidationError.identityMismatch
            }
            phase = .awaitingFull(configuration)
        case (.awaitingConfiguration, .scene),
             (.awaitingConfiguration, .accessibility):
            throw ValidationError.missingConfiguration
        case (.awaitingFull, .configuration),
             (.awaitingAccessibility, .configuration),
             (.active, .configuration):
            throw ValidationError.unexpectedConfiguration
        case let (.awaitingFull(configuration), .scene(scene)):
            guard scene.kind == .full else {
                throw ValidationError.missingFullScene
            }
            try accept(
                scene,
                configuration: configuration
            )
            phase = .awaitingAccessibility(PendingAccessibility(
                configuration: configuration,
                contentSequence: scene.contentSequence,
                presentationSequence: scene.presentationSequence
            ))
        case (.awaitingAccessibility, .scene):
            throw ValidationError.missingAccessibility
        case let (.active(configuration), .scene(scene)):
            try accept(
                scene,
                configuration: configuration
            )
            phase = .awaitingAccessibility(PendingAccessibility(
                configuration: configuration,
                contentSequence: scene.contentSequence,
                presentationSequence: scene.presentationSequence
            ))
        case (.awaitingFull, .accessibility):
            throw ValidationError.missingFullScene
        case let (.awaitingAccessibility(pending), .accessibility(accessibility)):
            try accept(accessibility, pending: pending)
            phase = .active(pending.configuration)
        case (.active, .accessibility):
            throw ValidationError.accessibilitySceneMismatch
        }
    }

    private mutating func accept(
        _ scene: CmxIrohTerminalSceneFrame,
        configuration: CmxIrohTerminalSceneConfiguration
    ) throws {
        guard scene.terminalID == configuration.terminalID,
              scene.terminalEpoch == configuration.terminalEpoch,
              scene.presentationID == presentationID,
              scene.presentationGeneration == presentationGeneration else {
            throw ValidationError.identityMismatch
        }
        guard scene.presentationSequence == nextPresentationSequence else {
            throw ValidationError.presentationSequenceGap(
                expected: nextPresentationSequence,
                actual: scene.presentationSequence
            )
        }
        if let lastContentSequence, scene.contentSequence < lastContentSequence {
            throw ValidationError.contentSequenceRegression(
                previous: lastContentSequence,
                actual: scene.contentSequence
            )
        }
        guard nextPresentationSequence != UInt64.max else {
            throw ValidationError.presentationSequenceExhausted
        }
        lastContentSequence = scene.contentSequence
        nextPresentationSequence += 1
    }

    private func accept(
        _ accessibility: CmxIrohTerminalSceneAccessibility,
        pending: PendingAccessibility
    ) throws {
        let configuration = pending.configuration
        guard accessibility.terminalID == configuration.terminalID,
              accessibility.terminalEpoch == configuration.terminalEpoch,
              accessibility.presentationID == presentationID,
              accessibility.presentationGeneration == presentationGeneration else {
            throw ValidationError.identityMismatch
        }
        guard accessibility.contentSequence == pending.contentSequence,
              accessibility.presentationSequence == pending.presentationSequence else {
            throw ValidationError.accessibilitySceneMismatch
        }
    }
}
