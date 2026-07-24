public import Foundation

/// Enforces one configuration, a full bootstrap, and contiguous presentation scenes.
public struct CmxIrohTerminalSceneStreamValidator: Sendable {
    /// Fail-closed reasons that require a fresh presentation generation.
    public enum ValidationError: Error, Equatable, Sendable {
        case missingConfiguration
        case unexpectedConfiguration
        case missingFullScene
        case identityMismatch
        case presentationSequenceGap(expected: UInt64, actual: UInt64)
        case contentSequenceRegression(previous: UInt64, actual: UInt64)
        case presentationSequenceExhausted
    }

    private enum Phase: Sendable {
        case awaitingConfiguration
        case awaitingFull(CmxIrohTerminalSceneConfiguration)
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
        case (.awaitingConfiguration, .scene):
            throw ValidationError.missingConfiguration
        case (.awaitingFull, .configuration),
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
            phase = .active(configuration)
        case let (.active(configuration), .scene(scene)):
            try accept(
                scene,
                configuration: configuration
            )
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
}
