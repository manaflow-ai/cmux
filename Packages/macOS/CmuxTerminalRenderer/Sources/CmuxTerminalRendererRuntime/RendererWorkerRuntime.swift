internal import CmuxTerminalRenderProtocol
public import CmuxTerminalRendererControl
internal import Foundation

/// Actor-isolated worker state. It never accepts PTY bytes or creates terminal I/O.
public actor RendererWorkerRuntime {
    public static let maximumCurrentPresentations = 256
    public static let maximumRetiredPresentations = 512
    public static let maximumLeasesPerPresentation = 3

    private enum Phase {
        case awaitingBootstrap
        case active(RendererBootstrap)
        case terminal
    }

    private struct PresentationLifetime: Hashable {
        let id: UUID
        let generation: UInt64
    }

    private final class PresentationRecord {
        let attachment: RendererPresentationAttachment
        let engine: any RendererPresentationEngine
        var inFlight: [UInt64: RendererFrameLease] = [:]
        var renderPending = false
        // The daemon attaches only visible presentations and removes them on
        // visibility loss. Retired records remain solely to release leases.
        var acceptsScenes = true
        var didPublishMetrics = false
        var lastCanonicalSequence: UInt64 = 0
        var lastPresentationSequence: UInt64 = 0
        var animationCancellation: (any RendererAnimationCancellation)?

        init(
            attachment: RendererPresentationAttachment,
            engine: any RendererPresentationEngine
        ) {
            self.attachment = attachment
            self.engine = engine
        }

        func cancelAnimation() {
            animationCancellation?.cancel()
            animationCancellation = nil
        }
    }

    private let expectation: RendererWorkerExpectation
    private let ready: RendererWorkerReady
    private let engineFactory: any RendererPresentationEngineFactory
    private let animationScheduler: any RendererAnimationScheduling
    private var phase = Phase.awaitingBootstrap
    private var records: [PresentationLifetime: PresentationRecord] = [:]
    private var currentLifetimes: [UUID: PresentationLifetime] = [:]
    private var highestGenerations: [UUID: UInt64] = [:]
    private var asynchronousFailure: RendererWorkerRuntimeError?

    public init(
        expectation: RendererWorkerExpectation,
        ready: RendererWorkerReady,
        engineFactory: any RendererPresentationEngineFactory,
        animationScheduler: any RendererAnimationScheduling =
            RendererDisplayAnimationScheduler()
    ) {
        self.expectation = expectation
        self.ready = ready
        self.engineFactory = engineFactory
        self.animationScheduler = animationScheduler
    }

    /// Applies one already-framed daemon command and fails closed on violations.
    public func handle(_ message: RendererControlMessage) async -> RendererWorkerRuntimeResult {
        do {
            return try await handleValidated(message)
        } catch {
            let runtimeError = normalize(error)
            await terminateResources()
            phase = .terminal
            return RendererWorkerRuntimeResult(
                replies: [makeFatal(for: runtimeError)],
                shouldExit: true
            )
        }
    }

    /// Releases all local resources after control-channel EOF or process teardown.
    public func terminate() async {
        guard case .terminal = phase else {
            await terminateResources()
            phase = .terminal
            return
        }
    }

    private func handleValidated(
        _ message: RendererControlMessage
    ) async throws -> RendererWorkerRuntimeResult {
        if let asynchronousFailure {
            self.asynchronousFailure = nil
            throw asynchronousFailure
        }
        switch phase {
        case .awaitingBootstrap:
            guard case let .bootstrap(bootstrap) = message else {
                throw RendererWorkerRuntimeError.expectedBootstrap
            }
            guard bootstrap.daemonInstanceID == expectation.daemonInstanceID,
                  bootstrap.workspaceID == expectation.workspaceID,
                  bootstrap.rendererEpoch == expectation.rendererEpoch else {
                throw RendererWorkerRuntimeError.bootstrapIdentityMismatch
            }
            phase = .active(bootstrap)
            return RendererWorkerRuntimeResult(replies: [.ready(ready)])

        case let .active(bootstrap):
            switch message {
            case .bootstrap:
                throw RendererWorkerRuntimeError.duplicateBootstrap
            case .ready, .needsFullScene, .fatal, .presentationReady:
                throw RendererWorkerRuntimeError.commandAfterTermination
            case let .upsertPresentation(attachment):
                try await upsert(attachment, bootstrap: bootstrap)
                return RendererWorkerRuntimeResult()
            case let .removePresentation(removal):
                try await remove(removal)
                return RendererWorkerRuntimeResult()
            case let .semanticScene(scene):
                let replies = try await apply(scene, bootstrap: bootstrap)
                return RendererWorkerRuntimeResult(replies: replies)
            case let .frameRelease(release):
                let replies = try await releaseFrame(release, bootstrap: bootstrap)
                return RendererWorkerRuntimeResult(replies: replies)
            case .shutdown:
                await terminateResources()
                phase = .terminal
                return RendererWorkerRuntimeResult(shouldExit: true)
            }

        case .terminal:
            throw RendererWorkerRuntimeError.commandAfterTermination
        }
    }

    private func upsert(
        _ attachment: RendererPresentationAttachment,
        bootstrap: RendererBootstrap
    ) async throws {
        guard attachment.terminalEpoch != 0,
              attachment.pixelFormat == .bgra8Unorm else {
            throw RendererWorkerRuntimeError.invalidPresentation
        }
        if let previousGeneration = highestGenerations[attachment.presentationID],
           attachment.presentationGeneration <= previousGeneration {
            throw RendererWorkerRuntimeError.stalePresentationGeneration
        }
        if currentLifetimes[attachment.presentationID] == nil,
           currentLifetimes.count >= Self.maximumCurrentPresentations {
            throw RendererWorkerRuntimeError.presentationLimitExceeded
        }

        if let previous = currentLifetimes[attachment.presentationID] {
            guard let record = records[previous],
                  record.attachment.terminalID == attachment.terminalID,
                  record.attachment.terminalEpoch == attachment.terminalEpoch else {
                throw RendererWorkerRuntimeError.invalidPresentation
            }
            record.acceptsScenes = false
            record.cancelAnimation()
            currentLifetimes.removeValue(forKey: attachment.presentationID)
            try await reapIfUnused(previous)
        }

        let retiredCount = records.values.lazy.filter { !$0.acceptsScenes }.count
        guard retiredCount < Self.maximumRetiredPresentations else {
            throw RendererWorkerRuntimeError.retiredPresentationLimitExceeded
        }
        let context = RendererPresentationEngineContext(
            daemonInstanceID: bootstrap.daemonInstanceID,
            rendererEpoch: bootstrap.rendererEpoch,
            attachment: attachment
        )
        let engine: any RendererPresentationEngine
        do {
            engine = try engineFactory.makeEngine(context: context)
        } catch {
            throw normalizeEngine(error)
        }
        let lifetime = PresentationLifetime(
            id: attachment.presentationID,
            generation: attachment.presentationGeneration
        )
        records[lifetime] = PresentationRecord(attachment: attachment, engine: engine)
        currentLifetimes[attachment.presentationID] = lifetime
        highestGenerations[attachment.presentationID] = attachment.presentationGeneration
    }

    private func remove(_ removal: RendererPresentationRemoval) async throws {
        let lifetime = PresentationLifetime(
            id: removal.presentationID,
            generation: removal.presentationGeneration
        )
        guard currentLifetimes[removal.presentationID] == lifetime,
              let record = records[lifetime],
              record.attachment.terminalID == removal.terminalID,
              record.attachment.terminalEpoch == removal.terminalEpoch else {
            throw RendererWorkerRuntimeError.unknownPresentation
        }
        record.acceptsScenes = false
        record.cancelAnimation()
        currentLifetimes.removeValue(forKey: removal.presentationID)
        try await reapIfUnused(lifetime)
    }

    private func apply(
        _ scene: RendererSemanticScene,
        bootstrap: RendererBootstrap
    ) async throws -> [RendererControlMessage] {
        let lifetime = PresentationLifetime(
            id: scene.presentationID,
            generation: scene.presentationGeneration
        )
        guard currentLifetimes[scene.presentationID] == lifetime,
              let record = records[lifetime],
              record.acceptsScenes,
              record.attachment.terminalID == scene.terminalID,
              record.attachment.terminalEpoch == scene.terminalEpoch else {
            throw RendererWorkerRuntimeError.sceneIdentityMismatch
        }

        do {
            try record.engine.apply(scene: scene)
        } catch let error as RendererPresentationEngineError {
            switch error {
            case .invalidScene:
                return [try needsFullScene(
                    record: record,
                    reason: .decodeFailure
                )]
            case .replayRejected:
                return [try needsFullScene(
                    record: record,
                    reason: .sequenceGap
                )]
            default:
                throw RendererWorkerRuntimeError.engine(error)
            }
        } catch {
            throw normalizeEngine(error)
        }

        record.lastCanonicalSequence = scene.canonicalSequence
        record.lastPresentationSequence = scene.presentationSequence
        var replies = try await renderAndPublish(record, bootstrap: bootstrap)
        if !record.didPublishMetrics {
            let geometry: RendererPresentationGeometry
            do {
                geometry = try record.engine.metrics()
            } catch {
                throw normalizeEngine(error)
            }
            replies.insert(.presentationReady(try RendererPresentationReady(
                terminalID: scene.terminalID,
                terminalEpoch: scene.terminalEpoch,
                presentationID: scene.presentationID,
                presentationGeneration: scene.presentationGeneration,
                canonicalSequence: scene.canonicalSequence,
                presentationSequence: scene.presentationSequence,
                columns: geometry.columns,
                rows: geometry.rows,
                cellWidth: geometry.cellWidth,
                cellHeight: geometry.cellHeight,
                paddingTop: geometry.paddingTop,
                paddingRight: geometry.paddingRight,
                paddingBottom: geometry.paddingBottom,
                paddingLeft: geometry.paddingLeft
            )), at: 0)
            record.didPublishMetrics = true
        }
        try synchronizeAnimation(lifetime: lifetime, record: record)
        return replies
    }

    private func releaseFrame(
        _ release: RendererControlFrameRelease,
        bootstrap: RendererBootstrap
    ) async throws -> [RendererControlMessage] {
        guard release.daemonInstanceID == bootstrap.daemonInstanceID,
              release.rendererEpoch == bootstrap.rendererEpoch else {
            throw RendererWorkerRuntimeError.releaseIdentityMismatch
        }
        let lifetime = PresentationLifetime(
            id: release.presentationID,
            generation: release.presentationGeneration
        )
        guard let record = records[lifetime],
              let lease = record.inFlight.removeValue(forKey: release.frameSequence) else {
            throw RendererWorkerRuntimeError.unknownFrameLease
        }
        guard lease.rendererEpoch == release.rendererEpoch,
              lease.terminalID == release.terminalID,
              lease.terminalEpoch == release.terminalEpoch,
              lease.terminalSequence == release.terminalSequence,
              lease.presentationID == release.presentationID,
              lease.presentationGeneration == release.presentationGeneration,
              lease.frameSequence == release.frameSequence,
              lease.surfaceID == release.surfaceID else {
            record.inFlight[lease.frameSequence] = lease
            throw RendererWorkerRuntimeError.releaseIdentityMismatch
        }
        do {
            try record.engine.release(lease: lease)
        } catch {
            throw normalizeEngine(error)
        }

        if !record.acceptsScenes {
            try await reapIfUnused(lifetime)
            return []
        }
        if record.renderPending {
            let replies = try await renderAndPublish(record, bootstrap: bootstrap)
            try synchronizeAnimation(lifetime: lifetime, record: record)
            return replies
        }
        try synchronizeAnimation(lifetime: lifetime, record: record)
        return []
    }

    private func renderAndPublish(
        _ record: PresentationRecord,
        bootstrap: RendererBootstrap
    ) async throws -> [RendererControlMessage] {
        let lease: RendererFrameLease
        do {
            lease = try record.engine.render()
        } catch let error as RendererPresentationEngineError where error == .busy {
            record.renderPending = true
            return []
        } catch {
            throw normalizeEngine(error)
        }

        guard lease.rendererEpoch == bootstrap.rendererEpoch,
              lease.terminalID == record.attachment.terminalID,
              lease.terminalEpoch == record.attachment.terminalEpoch,
              lease.terminalSequence == record.lastCanonicalSequence,
              lease.presentationID == record.attachment.presentationID,
              lease.presentationGeneration == record.attachment.presentationGeneration,
              lease.presentationSequence == record.lastPresentationSequence,
              lease.width == record.attachment.width,
              lease.height == record.attachment.height,
              record.inFlight[lease.frameSequence] == nil,
              record.inFlight.count < Self.maximumLeasesPerPresentation else {
            try? record.engine.release(lease: lease)
            throw RendererWorkerRuntimeError.engine(.invariantViolation)
        }

        let metadata = try TerminalRenderFrameMetadata(
            daemonInstanceID: bootstrap.daemonInstanceID,
            rendererEpoch: lease.rendererEpoch,
            terminalID: lease.terminalID,
            terminalEpoch: lease.terminalEpoch,
            terminalSequence: lease.terminalSequence,
            presentationID: lease.presentationID,
            presentationGeneration: lease.presentationGeneration,
            frameSequence: lease.frameSequence,
            width: lease.width,
            height: lease.height,
            pixelFormat: record.attachment.pixelFormat,
            colorSpace: record.attachment.colorSpace,
            completionFence: .producerCompleted,
            damageBounds: nil
        )
        record.inFlight[lease.frameSequence] = lease
        let disposition: RendererFramePublishDisposition
        do {
            disposition = try await record.engine.publish(lease: lease, metadata: metadata)
        } catch {
            record.inFlight.removeValue(forKey: lease.frameSequence)
            try? record.engine.release(lease: lease)
            throw RendererWorkerRuntimeError.engine(.frameTransportFailure)
        }
        switch disposition {
        case .sent:
            record.renderPending = false
        case .droppedQueueFull:
            record.inFlight.removeValue(forKey: lease.frameSequence)
            do {
                try record.engine.release(lease: lease)
            } catch {
                throw normalizeEngine(error)
            }
            record.renderPending = true
        }
        return []
    }

    private func needsFullScene(
        record: PresentationRecord,
        reason: RendererNeedsFullSceneReason
    ) throws -> RendererControlMessage {
        .needsFullScene(try RendererNeedsFullScene(
            terminalID: record.attachment.terminalID,
            terminalEpoch: record.attachment.terminalEpoch,
            presentationID: record.attachment.presentationID,
            presentationGeneration: record.attachment.presentationGeneration,
            lastCanonicalSequence: record.lastCanonicalSequence,
            lastPresentationSequence: record.lastPresentationSequence,
            reason: reason
        ))
    }

    private func synchronizeAnimation(
        lifetime: PresentationLifetime,
        record: PresentationRecord
    ) throws {
        guard record.acceptsScenes,
              record.inFlight.count < Self.maximumLeasesPerPresentation,
              !record.renderPending,
              try record.engine.shouldAnimate(visible: record.acceptsScenes) else {
            record.cancelAnimation()
            return
        }
        guard record.animationCancellation == nil else { return }
        record.animationCancellation = animationScheduler.schedule { [weak self] in
            await self?.animationTick(lifetime: lifetime)
        }
    }

    private func animationTick(lifetime: PresentationLifetime) async {
        guard case let .active(bootstrap) = phase,
              currentLifetimes[lifetime.id] == lifetime,
              let record = records[lifetime],
              record.acceptsScenes else {
            records[lifetime]?.cancelAnimation()
            return
        }
        record.animationCancellation = nil
        do {
            guard record.inFlight.count < Self.maximumLeasesPerPresentation,
                  !record.renderPending,
                  try record.engine.shouldAnimate(visible: record.acceptsScenes) else {
                return
            }
            _ = try await renderAndPublish(record, bootstrap: bootstrap)
            try synchronizeAnimation(lifetime: lifetime, record: record)
        } catch {
            record.cancelAnimation()
            asynchronousFailure = normalize(error)
            for value in records.values {
                value.cancelAnimation()
            }
        }
    }

    private func reapIfUnused(_ lifetime: PresentationLifetime) async throws {
        guard let record = records[lifetime],
              !record.acceptsScenes,
              record.inFlight.isEmpty else { return }
        record.cancelAnimation()
        do {
            try await record.engine.close()
        } catch {
            throw normalizeEngine(error)
        }
        records.removeValue(forKey: lifetime)
    }

    private func terminateResources() async {
        for record in records.values {
            record.cancelAnimation()
            for lease in record.inFlight.values {
                try? record.engine.release(lease: lease)
            }
            record.inFlight.removeAll(keepingCapacity: false)
            try? await record.engine.close()
        }
        records.removeAll(keepingCapacity: false)
        currentLifetimes.removeAll(keepingCapacity: false)
        highestGenerations.removeAll(keepingCapacity: false)
    }

    private func normalize(_ error: any Error) -> RendererWorkerRuntimeError {
        if let value = error as? RendererWorkerRuntimeError {
            return value
        }
        return normalizeEngine(error)
    }

    private func normalizeEngine(_ error: any Error) -> RendererWorkerRuntimeError {
        if let value = error as? RendererPresentationEngineError {
            return .engine(value)
        }
        return .engineFailure(String(describing: error))
    }

    private func makeFatal(for error: RendererWorkerRuntimeError) -> RendererControlMessage {
        let code: RendererFatalCode = switch error {
        case .expectedBootstrap, .bootstrapIdentityMismatch, .duplicateBootstrap,
             .commandAfterTermination, .invalidPresentation, .stalePresentationGeneration,
             .unknownPresentation, .sceneIdentityMismatch, .releaseIdentityMismatch,
             .unknownFrameLease:
            .protocolViolation
        case .presentationLimitExceeded, .retiredPresentationLimitExceeded:
            .resourceExhausted
        case let .engine(value):
            switch value {
            case .invalidScene, .replayRejected, .unsupportedSceneCapability:
                .sceneDecodeFailure
            case .resourceExhausted:
                .resourceExhausted
            case .gpuFailure, .busy:
                .renderFailure
            case .frameTransportFailure:
                .frameTransportFailure
            case .invariantViolation:
                .internalInvariant
            }
        case .engineFailure:
            .rendererInitializationFailure
        }
        let diagnostic = Self.boundedDiagnostic(error.diagnostic)
        return .fatal(try! RendererFatal(code: code, diagnostic: diagnostic))
    }

    private static func boundedDiagnostic(_ value: String) -> String {
        let maximum = RendererControlProtocol.maximumDiagnosticLength
        guard value.utf8.count > maximum else { return value }
        var result = value
        while result.utf8.count > maximum {
            result.removeLast()
        }
        return result
    }
}
