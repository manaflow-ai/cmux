import Foundation

/// Owns bounded scan admission, output pacing, cancellation, and worker completion.
@MainActor
final class TerminalInlineImageScanCoordinator {
    private nonisolated static let outputCadence: Duration = .milliseconds(200)

    private weak var delegate: (any TerminalInlineImageScanCoordinatorDelegate)?
    private let scannerService: TerminalInlineImageScannerService
    private let pacingSleep: @Sendable (Duration) async throws -> Void
    private var gate = TerminalInlineImageScanGate()
    private var scanTask: Task<Void, Never>?
    private var pacingTask: Task<Void, Never>?
    private var pacedWorkID: UUID?
    private var hasUrgentPendingScan = false

    init(
        delegate: any TerminalInlineImageScanCoordinatorDelegate,
        scannerService: TerminalInlineImageScannerService,
        pacingSleep: @escaping @Sendable (Duration) async throws -> Void
    ) {
        self.delegate = delegate
        self.scannerService = scannerService
        self.pacingSleep = pacingSleep
    }

    deinit {
        scanTask?.cancel()
        pacingTask?.cancel()
    }

    func request(paced: Bool) {
        if let pacedWorkID {
            guard !paced else { return }
            pacingTask?.cancel()
            pacingTask = nil
            self.pacedWorkID = nil
            captureAndStart(workID: pacedWorkID)
            return
        }
        guard let workID = gate.requestScan() else {
            if !paced {
                hasUrgentPendingScan = true
            }
            return
        }
        startReserved(workID: workID, paced: paced)
    }

    func cancelSession() {
        gate.discardPendingScan()
        scanTask?.cancel()
        pacingTask?.cancel()
        pacingTask = nil
        if let pacedWorkID {
            gate.cancelScan(pacedWorkID)
        }
        pacedWorkID = nil
        hasUrgentPendingScan = false
    }

    private func startReserved(workID: UUID, paced: Bool) {
        guard paced else {
            captureAndStart(workID: workID)
            return
        }
        pacedWorkID = workID
        let sleep = pacingSleep
        pacingTask = Task { @MainActor [weak self, sleep] in
            // This is intentional output-rate pacing, not a state-settling delay.
            // The injected sleep is cancelled on every surface-session transition.
            do {
                try await sleep(Self.outputCadence)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let self,
                  self.pacedWorkID == workID else {
                return
            }
            self.pacingTask = nil
            self.pacedWorkID = nil
            self.captureAndStart(workID: workID)
        }
    }

    private func captureAndStart(workID: UUID) {
        guard let request = delegate?.scanCoordinatorRequest(workID: workID) else {
            finishWithoutResult(workID: workID)
            return
        }
        let scannerService = scannerService
        scanTask = Task { [weak self, request, scannerService] in
            let detected = await scannerService.scan(request)
            guard let self else { return }
            self.scanDidComplete(
                request,
                detected: detected,
                wasCancelled: Task.isCancelled
            )
        }
    }

    private func scanDidComplete(
        _ request: TerminalInlineImageScanRequest,
        detected: [DetectedImagePath]?,
        wasCancelled: Bool
    ) {
        scanTask = nil
        let nextWorkID = gate.completeScan(request.workID)
        if !wasCancelled {
            delegate?.scanCoordinatorApply(detected, request: request)
        }
        startFollowUpIfNeeded(nextWorkID)
    }

    private func finishWithoutResult(workID: UUID) {
        scanTask = nil
        startFollowUpIfNeeded(gate.completeScan(workID))
    }

    private func startFollowUpIfNeeded(_ workID: UUID?) {
        guard let workID else { return }
        let shouldPace = !hasUrgentPendingScan
        hasUrgentPendingScan = false
        startReserved(workID: workID, paced: shouldPace)
    }
}
