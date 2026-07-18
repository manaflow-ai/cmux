import CmuxTerminal
import CmuxTerminalBackend
import Foundation

enum TerminalBackendRemoteTmuxBridgeError: Error, Equatable {
    case claimIdentityMismatch
    case resetIdentityMismatch
    case outputIdentityMismatch
    case egressDeliveryFailed
    case seedUnavailable
}

/// Routes runtime mutations through the same ordered lane as external tmux
/// output, so parser-generated egress cannot overtake a `%output` write.
@MainActor
protocol TerminalBackendExternalRuntimeMutationRouting: AnyObject {
    func apply(
        _ mutation: TerminalExternalRuntimeMutation,
        requestID: UUID,
        client: any TerminalBackendClient,
        binding: TerminalBackendTerminalBinding,
        presentation: TerminalBackendPresentationDescriptor?
    ) async throws -> TerminalBackendMutationOutcome
}

/// Connection-owned bridge between one remote tmux pane and one parser-only
/// cmuxd terminal. Every reset, output write, runtime input, and egress drain is
/// serialized through one lane with explicit owner/generation/sequence fences.
@MainActor
final class TerminalBackendRemoteTmuxSurfaceBridge:
    TerminalBackendExternalRuntimeMutationRouting
{
    typealias SendKeys = @MainActor @Sendable (Data) -> Bool
    typealias RequestSeed = @MainActor @Sendable () -> Void
    typealias RecoveryHandler = @Sendable () async -> Void

    private enum Phase: Equatable {
        case needsSeed
        case resetting
        case ready
        case retired
    }

    private struct Ownership {
        let ownerGeneration: UInt64
        var outputGeneration: UInt64
        var nextSequence: UInt64
        var noReflow: Bool
    }

    private enum OutputContext {
        case ready
        case resetting(seedRevision: UInt64)
    }

    let surfaceID: SurfaceID
    private let service: any TerminalBackendExternalTerminalServing
    private var sendKeys: SendKeys
    private var requestSeed: RequestSeed
    private let recoveryHandler: RecoveryHandler

    private var phase = Phase.needsSeed
    private var ownership: Ownership?
    private var claimRequestID: UUID?
    private var active = false
    private var epoch: UInt64 = 0
    private var pendingSeed: (
        revision: UInt64,
        seed: RemoteTmuxPaneSeed,
        columns: UInt16,
        rows: UInt16,
        noReflow: Bool
    )?
    private var seedRevision: UInt64 = 0
    private var desiredNoReflow = true
    private var pendingPostSeedOutput: [Data] = []
    private var pendingPostSeedOutputBytes = 0
    private var readyWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var scheduledTail: Task<Void, Never>?
    private var operationTail: Task<Void, Never>?
    private var scheduledIssued: UInt64 = 0
    private var scheduledFinished: UInt64 = 0
    private var operationIssued: UInt64 = 0
    private var operationFinished: UInt64 = 0
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var seedFailureRetryAvailable = true
    private var seedRequestOutstanding = false
    private var recoveryTask: Task<Void, Never>?
    private var operationCancellations: [UUID: @MainActor () -> Void] = [:]

    init(
        surfaceID: SurfaceID,
        service: any TerminalBackendExternalTerminalServing,
        sendKeys: @escaping SendKeys,
        requestSeed: @escaping RequestSeed,
        recoveryHandler: @escaping RecoveryHandler = {}
    ) {
        self.surfaceID = surfaceID
        self.service = service
        self.sendKeys = sendKeys
        self.requestSeed = requestSeed
        self.recoveryHandler = recoveryHandler
    }

    func updateEndpoints(
        sendKeys: @escaping SendKeys,
        requestSeed: @escaping RequestSeed,
        requestSeedIfNeeded: Bool = false
    ) {
        self.sendKeys = sendKeys
        self.requestSeed = requestSeed
        if requestSeedIfNeeded, active, phase == .needsSeed {
            seedRequestOutstanding = false
            requestFreshSeed()
        }
    }

    func activate() {
        guard !active, phase != .retired else { return }
        active = true
        let activationEpoch = epoch
        schedule { [weak self] in
            guard let self else { return }
            do {
                try await self.performOrdered {
                    guard self.epoch == activationEpoch, self.phase != .retired else { return }
                    try await self.ensureClaim()
                }
                guard self.epoch == activationEpoch, self.phase != .retired else { return }
                if self.pendingSeed != nil {
                    self.schedulePendingSeedReset()
                } else {
                    self.requestFreshSeed()
                }
            } catch is CancellationError {
                return
            } catch {
                self.handleBackendFailure(error)
            }
        }
    }

    func receiveSeed(
        _ seed: RemoteTmuxPaneSeed,
        columns: UInt16,
        rows: UInt16,
        noReflow: Bool
    ) {
        guard phase != .retired, columns > 0, rows > 0 else { return }
        seedRequestOutstanding = false
        epoch &+= 1
        seedRevision &+= 1
        desiredNoReflow = noReflow
        phase = .resetting
        pendingSeed = (seedRevision, seed, columns, rows, noReflow)
        pendingPostSeedOutput.removeAll(keepingCapacity: true)
        pendingPostSeedOutputBytes = 0
        seedFailureRetryAvailable = true
        guard active else { return }
        schedulePendingSeedReset()
    }

    func updateNoReflow(_ noReflow: Bool) {
        guard phase != .retired, desiredNoReflow != noReflow else { return }
        desiredNoReflow = noReflow
        guard active else { return }
        switch phase {
        case .ready:
            epoch &+= 1
            seedRevision &+= 1
            phase = .needsSeed
            seedRequestOutstanding = false
            requestFreshSeed()
        case .resetting:
            // The pending seed carries the prior policy. A fresh capture/reset
            // supersedes it and persists the new policy atomically.
            epoch &+= 1
            seedRevision &+= 1
            phase = .needsSeed
            pendingSeed = nil
            pendingPostSeedOutput.removeAll(keepingCapacity: false)
            pendingPostSeedOutputBytes = 0
            seedRequestOutstanding = false
            requestFreshSeed()
        case .needsSeed, .retired:
            break
        }
    }

    func receiveOutput(_ data: Data) {
        guard !data.isEmpty, phase != .retired else { return }
        switch phase {
        case .needsSeed:
            // The in-flight capture represents output before its snapshot. The
            // seed assembler diverts output after capture into the seed itself.
            return
        case .resetting:
            guard data.count <= Self.maximumBufferedOutputByteCount - pendingPostSeedOutputBytes else {
                seedFailed()
                return
            }
            appendBoundedOutput(data, to: &pendingPostSeedOutput)
            pendingPostSeedOutputBytes += data.count
        case .ready:
            scheduleOutput(data)
        case .retired:
            return
        }
    }

    func seedFailed() {
        guard phase != .retired else { return }
        seedRevision &+= 1
        phase = .needsSeed
        pendingSeed = nil
        pendingPostSeedOutput.removeAll(keepingCapacity: false)
        pendingPostSeedOutputBytes = 0
        seedRequestOutstanding = false
        guard active else { return }
        if seedFailureRetryAvailable {
            seedFailureRetryAvailable = false
            requestFreshSeed()
        } else {
            failReadyWaiters(TerminalBackendRemoteTmuxBridgeError.seedUnavailable)
            beginRecovery(requestSeedAfterRecovery: true)
        }
    }

    func remoteConnectionDidDisconnect() {
        guard phase != .retired else { return }
        epoch &+= 1
        seedRevision &+= 1
        phase = .needsSeed
        pendingSeed = nil
        pendingPostSeedOutput.removeAll(keepingCapacity: false)
        pendingPostSeedOutputBytes = 0
        seedFailureRetryAvailable = true
        seedRequestOutstanding = false
    }

    func retire() {
        guard phase != .retired else { return }
        epoch &+= 1
        seedRevision &+= 1
        phase = .retired
        active = false
        ownership = nil
        claimRequestID = nil
        pendingSeed = nil
        pendingPostSeedOutput.removeAll(keepingCapacity: false)
        operationTail?.cancel()
        operationTail = nil
        scheduledTail?.cancel()
        scheduledTail = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        for cancel in operationCancellations.values { cancel() }
        operationCancellations.removeAll(keepingCapacity: false)
        failReadyWaiters(CancellationError())
        resumeIdleWaitersIfNeeded(force: true)
    }

    func apply(
        _ mutation: TerminalExternalRuntimeMutation,
        requestID: UUID,
        client: any TerminalBackendClient,
        binding: TerminalBackendTerminalBinding,
        presentation: TerminalBackendPresentationDescriptor?
    ) async throws -> TerminalBackendMutationOutcome {
        let mutationEpoch = epoch
        if mutation.requiresExternalTerminalSeed {
            try await waitUntilReady()
        }
        do {
            return try await performOrdered {
                guard self.epoch == mutationEpoch, self.phase != .retired else {
                    throw CancellationError()
                }
                let outcome = try await client.apply(
                    mutation,
                    requestID: requestID,
                    to: binding,
                    presentation: presentation
                )
                guard self.epoch == mutationEpoch, self.phase != .retired else {
                    throw CancellationError()
                }
                if self.phase == .ready {
                    try await self.drainEgress(expectedEpoch: mutationEpoch)
                }
                return outcome
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            handleBackendFailure(error)
            throw error
        }
    }

    func backendConnectionDidDisconnect() {
        guard phase != .retired else { return }
        epoch &+= 1
        seedRevision &+= 1
        phase = .needsSeed
        ownership = nil
        claimRequestID = nil
        pendingRequiredOutputGeneration = nil
        pendingSeed = nil
        pendingPostSeedOutput.removeAll(keepingCapacity: false)
        pendingPostSeedOutputBytes = 0
        seedRequestOutstanding = false
        recoveryTask?.cancel()
        recoveryTask = nil
        failReadyWaiters(BackendProtocolError.connectionClosed)
        for cancel in operationCancellations.values { cancel() }
        operationCancellations.removeAll(keepingCapacity: false)
    }

    func backendConnectionDidReconnect() {
        guard active, phase != .retired else { return }
        let reconnectEpoch = epoch
        schedule { [weak self] in
            guard let self else { return }
            do {
                try await self.performOrdered {
                    guard self.epoch == reconnectEpoch, self.phase != .retired else { return }
                    try await self.ensureClaim()
                }
                guard self.epoch == reconnectEpoch, self.phase != .retired else { return }
                self.requestFreshSeed()
            } catch is CancellationError {
                return
            } catch {
                self.handleBackendFailure(error)
            }
        }
    }

    func waitForIdleForTesting() async {
        guard !isIdle else { return }
        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }

    func waitUntilReadyForTesting() async throws {
        try await waitUntilReady()
    }

    var readyWaiterCountForTesting: Int { readyWaiters.count }

    private func schedulePendingSeedReset() {
        guard active, pendingSeed != nil, phase == .resetting else { return }
        let scheduledEpoch = epoch
        guard let scheduledSeedRevision = pendingSeed?.revision else { return }
        schedule { [weak self] in
            guard let self else { return }
            do {
                try await self.performOrdered {
                    guard self.epoch == scheduledEpoch,
                          self.phase == .resetting,
                          let pending = self.pendingSeed,
                          pending.revision == scheduledSeedRevision else { return }
                    try await self.ensureClaim(expectedEpoch: scheduledEpoch)
                    guard var ownership = self.ownership else {
                        throw TerminalBackendRemoteTmuxBridgeError.claimIdentityMismatch
                    }
                    let (nextGeneration, overflow) = ownership.outputGeneration
                        .addingReportingOverflow(1)
                    guard !overflow else {
                        throw TerminalBackendRemoteTmuxBridgeError.resetIdentityMismatch
                    }
                    let outputGeneration = max(nextGeneration, self.requiredOutputGeneration)
                    let requestID = UUID()
                    let receipt = try await self.service.resetExternalTerminal(
                        surfaceID: self.surfaceID,
                        ownerGeneration: ownership.ownerGeneration,
                        requestID: requestID,
                        outputGeneration: outputGeneration,
                        columns: pending.columns,
                        rows: pending.rows,
                        noReflow: pending.noReflow,
                        seed: pending.seed.reset
                    )
                    guard self.epoch == scheduledEpoch,
                          self.phase == .resetting,
                          self.pendingSeed?.revision == scheduledSeedRevision else {
                        throw CancellationError()
                    }
                    try self.validateReset(
                        receipt,
                        requestID: requestID,
                        ownership: ownership,
                        outputGeneration: outputGeneration,
                        noReflow: pending.noReflow
                    )
                    ownership.outputGeneration = outputGeneration
                    ownership.nextSequence = receipt.nextSequence
                    ownership.noReflow = receipt.noReflow
                    self.ownership = ownership
                    try self.forwardEgress(receipt.egress)

                    for chunk in pending.seed.output {
                        guard self.epoch == scheduledEpoch,
                              self.pendingSeed?.revision == scheduledSeedRevision else { return }
                        try await self.sendOutputNow(
                            chunk,
                            expectedEpoch: scheduledEpoch,
                            context: .resetting(seedRevision: scheduledSeedRevision)
                        )
                    }
                    guard self.epoch == scheduledEpoch,
                          self.pendingSeed?.revision == scheduledSeedRevision else { return }
                    while !self.pendingPostSeedOutput.isEmpty {
                        let chunks = self.pendingPostSeedOutput
                        self.pendingPostSeedOutput.removeAll(keepingCapacity: true)
                        self.pendingPostSeedOutputBytes = 0
                        for chunk in chunks {
                            try await self.sendOutputNow(
                                chunk,
                                expectedEpoch: scheduledEpoch,
                                context: .resetting(seedRevision: scheduledSeedRevision)
                            )
                        }
                    }
                    guard self.epoch == scheduledEpoch,
                          self.phase == .resetting,
                          self.pendingSeed?.revision == scheduledSeedRevision,
                          self.seedRevision == scheduledSeedRevision else { return }
                    self.pendingSeed = nil
                    self.phase = .ready
                    self.resumeReadyWaiters()
                }
            } catch is CancellationError {
                return
            } catch {
                self.handleBackendFailure(error)
            }
        }
    }

    private func scheduleOutput(_ data: Data) {
        let chunks = RemoteTmuxPaneSeed(reset: Data(), output: []).splitOutput(data)
        let scheduledEpoch = epoch
        schedule { [weak self] in
            guard let self else { return }
            do {
                try await self.performOrdered {
                    guard self.epoch == scheduledEpoch, self.phase == .ready else { return }
                    for chunk in chunks {
                        try await self.sendOutputNow(
                            chunk,
                            expectedEpoch: scheduledEpoch,
                            context: .ready
                        )
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                self.handleBackendFailure(error)
            }
        }
    }

    private var requiredOutputGeneration: UInt64 {
        pendingRequiredOutputGeneration ?? 1
    }

    private var pendingRequiredOutputGeneration: UInt64?

    private func ensureClaim(expectedEpoch: UInt64? = nil) async throws {
        guard ownership == nil else { return }
        let claimEpoch = expectedEpoch ?? epoch
        let requestID = claimRequestID ?? UUID()
        claimRequestID = requestID
        let receipt = try await service.claimExternalTerminal(
            surfaceID: surfaceID,
            requestID: requestID
        )
        guard epoch == claimEpoch, phase != .retired else {
            throw CancellationError()
        }
        guard receipt.requestID == requestID,
              receipt.ownerGeneration > 0,
              receipt.requiredOutputGeneration > 0 else {
            throw TerminalBackendRemoteTmuxBridgeError.claimIdentityMismatch
        }
        ownership = Ownership(
            ownerGeneration: receipt.ownerGeneration,
            outputGeneration: receipt.requiredOutputGeneration &- 1,
            nextSequence: 1,
            noReflow: desiredNoReflow
        )
        pendingRequiredOutputGeneration = receipt.requiredOutputGeneration
    }

    private func sendOutputNow(
        _ data: Data,
        expectedEpoch: UInt64,
        context: OutputContext
    ) async throws {
        guard !data.isEmpty, let ownership else { return }
        let requestID = UUID()
        let receipt = try await service.sendExternalTerminalOutput(
            surfaceID: surfaceID,
            ownerGeneration: ownership.ownerGeneration,
            requestID: requestID,
            outputGeneration: ownership.outputGeneration,
            sequence: ownership.nextSequence,
            data: data
        )
        guard epoch == expectedEpoch else { throw CancellationError() }
        switch context {
        case .ready:
            guard phase == .ready else { throw CancellationError() }
        case .resetting(let expectedSeedRevision):
            guard phase == .resetting,
                  pendingSeed?.revision == expectedSeedRevision else {
                throw CancellationError()
            }
        }
        guard receipt.requestID == requestID,
              receipt.ownerGeneration == ownership.ownerGeneration,
              receipt.outputGeneration == ownership.outputGeneration,
              receipt.acceptedSequence == ownership.nextSequence,
              receipt.nextSequence == ownership.nextSequence &+ 1,
              receipt.noReflow == ownership.noReflow else {
            throw TerminalBackendRemoteTmuxBridgeError.outputIdentityMismatch
        }
        self.ownership?.nextSequence = receipt.nextSequence
        try forwardEgress(receipt.egress)
    }

    private func validateReset(
        _ receipt: BackendExternalTerminalOutputReceipt,
        requestID: UUID,
        ownership: Ownership,
        outputGeneration: UInt64,
        noReflow: Bool
    ) throws {
        guard receipt.requestID == requestID,
              receipt.ownerGeneration == ownership.ownerGeneration,
              receipt.outputGeneration == outputGeneration,
              receipt.acceptedSequence == 0,
              receipt.nextSequence == 1,
              receipt.noReflow == noReflow else {
            throw TerminalBackendRemoteTmuxBridgeError.resetIdentityMismatch
        }
    }

    private func drainEgress(expectedEpoch: UInt64) async throws {
        guard let ownership else { return }
        let data = try await service.drainExternalTerminalEgress(
            surfaceID: surfaceID,
            ownerGeneration: ownership.ownerGeneration
        )
        guard epoch == expectedEpoch, phase == .ready else {
            throw CancellationError()
        }
        try forwardEgress(data)
    }

    private func forwardEgress(_ data: Data) throws {
        guard data.isEmpty || sendKeys(data) else {
            throw TerminalBackendRemoteTmuxBridgeError.egressDeliveryFailed
        }
    }

    private func appendBoundedOutput(_ data: Data, to output: inout [Data]) {
        output.append(contentsOf: RemoteTmuxPaneSeed(reset: Data(), output: []).splitOutput(data))
    }

    private func waitUntilReady() async throws {
        if phase == .ready { return }
        if phase == .retired { throw CancellationError() }
        let token = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                readyWaiters[token] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.readyWaiters.removeValue(forKey: token)?.resume(throwing: CancellationError())
            }
        }
    }

    private func resumeReadyWaiters() {
        let waiters = readyWaiters.values
        readyWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
    }

    private func failReadyWaiters(_ error: any Error) {
        let waiters = readyWaiters.values
        readyWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume(throwing: error) }
    }

    private func handleBackendFailure(_ error: any Error) {
        guard phase != .retired else { return }
        epoch &+= 1
        seedRevision &+= 1
        phase = .needsSeed
        ownership = nil
        claimRequestID = nil
        pendingRequiredOutputGeneration = nil
        pendingSeed = nil
        pendingPostSeedOutput.removeAll(keepingCapacity: false)
        pendingPostSeedOutputBytes = 0
        failReadyWaiters(error)
        seedRequestOutstanding = false
        beginRecovery(requestSeedAfterRecovery: active)
    }

    private func performOrdered<T>(
        _ operation: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        operationIssued &+= 1
        let generation = operationIssued
        let operationID = UUID()
        let predecessor = operationTail
        let task = Task<T, any Error> { @MainActor in
            await predecessor?.value
            try Task.checkCancellation()
            return try await operation()
        }
        operationCancellations[operationID] = { task.cancel() }
        operationTail = Task { @MainActor in
            _ = try? await task.value
            self.operationCancellations.removeValue(forKey: operationID)
            self.operationFinished = max(self.operationFinished, generation)
            self.resumeIdleWaitersIfNeeded()
        }
        return try await task.value
    }

    private func schedule(_ operation: @escaping @MainActor () async -> Void) {
        scheduledIssued &+= 1
        let generation = scheduledIssued
        let predecessor = scheduledTail
        scheduledTail = Task { @MainActor in
            await predecessor?.value
            if !Task.isCancelled { await operation() }
            self.scheduledFinished = max(self.scheduledFinished, generation)
            self.resumeIdleWaitersIfNeeded()
        }
    }

    private var isIdle: Bool {
        scheduledFinished == scheduledIssued && operationFinished == operationIssued
    }

    private func requestFreshSeed() {
        guard active, phase == .needsSeed, !seedRequestOutstanding else { return }
        seedRequestOutstanding = true
        requestSeed()
    }

    private func beginRecovery(requestSeedAfterRecovery: Bool) {
        recoveryTask?.cancel()
        let recoveryEpoch = epoch
        recoveryTask = Task { [weak self, recoveryHandler] in
            await recoveryHandler()
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.epoch == recoveryEpoch, self.phase != .retired else { return }
                self.recoveryTask = nil
                if requestSeedAfterRecovery {
                    self.seedRequestOutstanding = false
                    self.requestFreshSeed()
                }
            }
        }
    }

    private func resumeIdleWaitersIfNeeded(force: Bool = false) {
        guard force || isIdle else { return }
        let waiters = idleWaiters
        idleWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
    }

    private static let maximumBufferedOutputByteCount =
        4 * RemoteTmuxPaneSeed.maximumChunkByteCount
}

private extension TerminalExternalRuntimeMutation {
    var requiresExternalTerminalSeed: Bool {
        switch self {
        case .input, .mouse:
            true
        default:
            false
        }
    }
}

private extension RemoteTmuxPaneSeed {
    func splitOutput(_ data: Data) -> [Data] {
        let split = RemoteTmuxPaneSeed(bytes: data)
        if split.reset.isEmpty { return split.output }
        return [split.reset] + split.output
    }
}
