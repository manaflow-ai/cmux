import Foundation
@testable import CmuxMobileCloud

/// Scripted Network Extension boundary.
@MainActor
final class FakeSystemVPNManager: CloudSystemVPNManaging {
    var isAvailable = true
    var hasSavedConfiguration = false
    var phase: CloudSystemVPNPhase = .off
    var onPhaseChange: (@MainActor (CloudSystemVPNPhase) -> Void)?
    var installed: [(configuration: String, scope: String)] = []
    var installedTeamIDs: [String?] = []
    var stops: [Bool] = []
    var refreshedScopes: [String] = []
    var refreshedTeamIDs: [String?] = []
    var installFailure: CloudSystemVPNError?
    var installDelay: Duration?
    var installIgnoresCancellation = false
    var stopDelay: Duration?
    var stopIgnoresCancellation = false
    var stopFailuresRemaining = 0
    var stopAttempts: [Bool] = []
    private var installDelayTask: Task<Void, Never>?
    private var stopDelayTask: Task<Void, Never>?
    private var installWasCancelled = false
    private let installCompletion = TestSignal()
    private let cancellation = TestSignal()
    private let stopCompletion = TestSignal()
    private(set) var cancelPendingOperationCount = 0
    private(set) var activeOperations = 0
    private(set) var maxConcurrentOperations = 0
    /// The phase iOS reports once a start is requested.
    var phaseAfterStart: CloudSystemVPNPhase = .connecting
    /// The phase iOS reports after a stop request.
    var phaseAfterStop: CloudSystemVPNPhase = .off

    func refresh(scope: String) async throws {
        try await refresh(scope: scope, teamID: nil)
    }

    func refresh(scope: String, teamID: String?) async throws {
        beginOperation()
        defer { endOperation() }
        refreshedScopes.append(scope)
        refreshedTeamIDs.append(teamID)
    }

    func installAndStart(configuration: String, scope: String) async throws {
        try await installAndStart(configuration: configuration, scope: scope, teamID: nil)
    }

    func installAndStart(
        configuration: String,
        scope: String,
        teamID: String?
    ) async throws {
        beginOperation()
        defer { endOperation() }
        installWasCancelled = false
        if let installFailure { throw installFailure }
        if let installDelay {
            let delayTask = Task<Void, Never> {
                do {
                    try await ContinuousClock().sleep(for: installDelay)
                } catch {
                }
            }
            installDelayTask = delayTask
            defer { installDelayTask = nil }
            await delayTask.value
            if !installIgnoresCancellation {
                guard !installWasCancelled else { throw CancellationError() }
                try Task.checkCancellation()
            }
        }
        installed.append((configuration, scope))
        installedTeamIDs.append(teamID)
        hasSavedConfiguration = true
        await installCompletion.signal()
        phase = phaseAfterStart
        onPhaseChange?(phase)
    }

    func cancelPendingOperation() {
        cancelPendingOperationCount += 1
        installWasCancelled = true
        if !installIgnoresCancellation {
            installDelayTask?.cancel()
        }
        installDelay = nil
        if !stopIgnoresCancellation {
            stopDelayTask?.cancel()
        }
        stopDelay = nil
        phase = .off
        Task { await cancellation.signal() }
    }

    func stop(removeConfiguration: Bool) async throws {
        beginOperation()
        defer { endOperation() }
        stopAttempts.append(removeConfiguration)
        if stopFailuresRemaining > 0 {
            stopFailuresRemaining -= 1
            throw CloudSystemVPNError.configuration
        }
        if let stopDelay {
            let delayTask = Task<Void, Never> {
                try? await ContinuousClock().sleep(for: stopDelay)
            }
            stopDelayTask = delayTask
            defer { stopDelayTask = nil }
            await delayTask.value
            if !stopIgnoresCancellation {
                try Task.checkCancellation()
            }
        }
        stops.append(removeConfiguration)
        if removeConfiguration {
            hasSavedConfiguration = false
        }
        await stopCompletion.signal()
        phase = phaseAfterStop
    }

    func waitForInstallCompletion() async {
        await installCompletion.wait()
    }

    func waitForCancellation() async {
        await cancellation.wait()
    }

    func waitForStopCompletion() async {
        await stopCompletion.wait()
    }

    private func beginOperation() {
        activeOperations += 1
        maxConcurrentOperations = max(maxConcurrentOperations, activeOperations)
    }

    private func endOperation() {
        activeOperations -= 1
    }

    /// Simulates iOS reporting a status change on its own.
    func report(_ phase: CloudSystemVPNPhase) {
        self.phase = phase
        onPhaseChange?(phase)
    }
}
