import CmuxTerminalBackend
import Foundation

protocol TerminalBackendFrontendConnectionRecovering: Sendable {
    func recoverFrontendConnection() async
}

enum TerminalBackendNativeBrowserRuntimeError: Error, Equatable, Sendable {
    case claimIdentityMismatch(surfaceID: SurfaceID)
    case sourceURLTooLarge(surfaceID: SurfaceID)
}

/// Owns the connection-private lease between canonical browser placement and
/// the process-local WKWebView runtime. URLs never enter topology snapshots,
/// mutation receipts, logs, or the Swift session snapshot.
@MainActor
final class TerminalBackendNativeBrowserRuntimeCoordinator {
    typealias FailureReporter = @MainActor (String) -> Void
    typealias RecoveryHandler = @Sendable () async -> Void

    private struct Claim {
        let authority: BackendAuthority
        let ownerGeneration: UInt64
        var sourceURL: URL?
        var sourceNeedsInstallation: Bool
    }

    private struct PendingSourceUpdate {
        let requestID: UUID
        let sourceURL: URL
    }

    private struct ClaimPreparation: Sendable {
        let surfaceID: SurfaceID
        let requestID: UUID
        let localSourceURL: URL?
        let wasPresented: Bool
    }

    private let service: any TerminalBackendFrontendNativeBrowserServing
    private let presentationRegistry: TerminalBackendNativeBrowserPresentationRegistry
    private let failureReporter: FailureReporter
    private let recoveryHandler: RecoveryHandler
    private let maximumSourceURLByteCount: Int
    private let maximumPendingSourceUpdateCount: Int
    private let maximumConcurrentClaimCount: Int

    private var claims: [SurfaceID: Claim] = [:]
    private var claimRequestIDs: [SurfaceID: UUID] = [:]
    private var pendingSourceUpdates: [SurfaceID: PendingSourceUpdate] = [:]
    private var sourceUpdateTasks: [SurfaceID: Task<Void, Never>] = [:]

    init(
        service: any TerminalBackendFrontendNativeBrowserServing,
        presentationRegistry: TerminalBackendNativeBrowserPresentationRegistry,
        maximumSourceURLByteCount: Int = 32 * 1_024,
        maximumPendingSourceUpdateCount: Int = 64,
        maximumConcurrentClaimCount: Int = 16,
        failureReporter: @escaping FailureReporter = { _ in },
        recoveryHandler: @escaping RecoveryHandler = {}
    ) {
        precondition(maximumSourceURLByteCount > 0)
        precondition(maximumPendingSourceUpdateCount > 0)
        precondition(maximumConcurrentClaimCount > 0)
        self.service = service
        self.presentationRegistry = presentationRegistry
        self.maximumSourceURLByteCount = maximumSourceURLByteCount
        self.maximumPendingSourceUpdateCount = maximumPendingSourceUpdateCount
        self.maximumConcurrentClaimCount = maximumConcurrentClaimCount
        self.failureReporter = failureReporter
        self.recoveryHandler = recoveryHandler
    }

    func claimBeforeProjection(
        authority: BackendAuthority,
        surfaceIDs: [SurfaceID],
        projector: any TerminalBackendTopologyProjecting
    ) async throws {
        var preparations: [ClaimPreparation] = []
        for surfaceID in surfaceIDs.sorted(by: {
            $0.rawValue.uuidString < $1.rawValue.uuidString
        }) {
            try Task.checkCancellation()
            if claims[surfaceID]?.authority == authority {
                continue
            }

            let pendingRequest = presentationRegistry.request(for: surfaceID)
            let localSourceURL = pendingRequest?.initialRequest?.url
                ?? pendingRequest?.url
                ?? projector.frontendNativeBrowserSourceURL(surfaceID: surfaceID)
            try validateSourceURL(localSourceURL, surfaceID: surfaceID)
            let wasPresented = projector.frontendNativeBrowserIsPresented(
                surfaceID: surfaceID
            )
            let requestID = claimRequestIDs[surfaceID] ?? UUID()
            claimRequestIDs[surfaceID] = requestID
            preparations.append(ClaimPreparation(
                surfaceID: surfaceID,
                requestID: requestID,
                localSourceURL: localSourceURL,
                wasPresented: wasPresented
            ))
        }

        let service = service
        for startIndex in stride(
            from: 0,
            to: preparations.count,
            by: maximumConcurrentClaimCount
        ) {
            try Task.checkCancellation()
            let endIndex = min(
                startIndex + maximumConcurrentClaimCount,
                preparations.count
            )
            let batch = Array(preparations[startIndex..<endIndex])
            let results = try await withThrowingTaskGroup(
                of: (ClaimPreparation, BackendFrontendNativeBrowserClaimReceipt).self,
                returning: [(ClaimPreparation, BackendFrontendNativeBrowserClaimReceipt)].self
            ) { group in
                for preparation in batch {
                    group.addTask {
                        let receipt = try await service.claimFrontendNativeBrowser(
                            surfaceID: preparation.surfaceID,
                            requestID: preparation.requestID,
                            sourceURL: preparation.localSourceURL
                        )
                        return (preparation, receipt)
                    }
                }
                var receipts: [
                    (ClaimPreparation, BackendFrontendNativeBrowserClaimReceipt)
                ] = []
                receipts.reserveCapacity(batch.count)
                for try await result in group {
                    receipts.append(result)
                }
                return receipts
            }
            for (preparation, receipt) in results {
                guard receipt.authority == authority,
                      receipt.surfaceID == preparation.surfaceID,
                      receipt.requestID == preparation.requestID else {
                    throw TerminalBackendNativeBrowserRuntimeError
                        .claimIdentityMismatch(surfaceID: preparation.surfaceID)
                }
                try validateSourceURL(
                    receipt.sourceURL,
                    surfaceID: preparation.surfaceID
                )
                claims[preparation.surfaceID] = Claim(
                    authority: receipt.authority,
                    ownerGeneration: receipt.ownerGeneration,
                    sourceURL: receipt.sourceURL ?? preparation.localSourceURL,
                    sourceNeedsInstallation: preparation.wasPresented
                        && receipt.sourceURL != nil
                        && receipt.sourceURL != preparation.localSourceURL
                )
            }
        }
    }

    /// Called only after the process-wide prepared projection commits and
    /// finalizes. Until this point private requests remain available so a
    /// rollback can retry without losing headers or the claim source.
    func projectionDidInstall(
        surfaceIDs: [SurfaceID],
        projector: any TerminalBackendTopologyProjecting
    ) {
        let activeSurfaceIDs = Set(surfaceIDs)
        for surfaceID in surfaceIDs {
            if let claim = claims[surfaceID],
               claim.sourceNeedsInstallation,
               let sourceURL = claim.sourceURL {
                projector.installFrontendNativeBrowserClaimSourceURL(
                    sourceURL,
                    surfaceID: surfaceID
                )
                claims[surfaceID]?.sourceNeedsInstallation = false
            }
            presentationRegistry.remove(surfaceID)
        }
        let retiredSurfaceIDs = claims.keys.filter {
            !activeSurfaceIDs.contains($0)
        }
        for surfaceID in retiredSurfaceIDs {
            releaseLocalState(surfaceID: surfaceID)
        }
    }

    func browserDidCommitSourceURL(_ sourceURL: URL, surfaceID: SurfaceID) {
        guard let claim = claims[surfaceID] else { return }
        do {
            try validateSourceURL(sourceURL, surfaceID: surfaceID)
        } catch {
            failRuntimeLease(surfaceID: surfaceID)
            return
        }
        if claim.sourceURL == sourceURL,
           pendingSourceUpdates[surfaceID] == nil {
            return
        }
        guard pendingSourceUpdates[surfaceID] != nil
                || sourceUpdateTasks[surfaceID] != nil
                || sourceUpdateTasks.count < maximumPendingSourceUpdateCount else {
            failRuntimeLease(surfaceID: surfaceID)
            return
        }
        pendingSourceUpdates[surfaceID] = PendingSourceUpdate(
            requestID: UUID(),
            sourceURL: sourceURL
        )
        guard sourceUpdateTasks[surfaceID] == nil else { return }
        sourceUpdateTasks[surfaceID] = Task { [weak self] in
            await self?.runSourceUpdateLoop(surfaceID: surfaceID)
        }
    }

    func claimedSourceURL(surfaceID: SurfaceID) -> URL? {
        claims[surfaceID]?.sourceURL
    }

    func releaseLocalState(surfaceID: SurfaceID) {
        sourceUpdateTasks.removeValue(forKey: surfaceID)?.cancel()
        pendingSourceUpdates.removeValue(forKey: surfaceID)
        claims.removeValue(forKey: surfaceID)
        claimRequestIDs.removeValue(forKey: surfaceID)
        presentationRegistry.remove(surfaceID)
    }

    func backendDidDisconnect() {
        for task in sourceUpdateTasks.values {
            task.cancel()
        }
        sourceUpdateTasks.removeAll(keepingCapacity: false)
        pendingSourceUpdates.removeAll(keepingCapacity: false)
        claims.removeAll(keepingCapacity: false)
        claimRequestIDs.removeAll(keepingCapacity: false)
        presentationRegistry.removeAll()
    }

    private func runSourceUpdateLoop(surfaceID: SurfaceID) async {
        defer { sourceUpdateTasks.removeValue(forKey: surfaceID) }
        while !Task.isCancelled {
            guard let update = pendingSourceUpdates[surfaceID],
                  let claim = claims[surfaceID] else {
                return
            }
            pendingSourceUpdates.removeValue(forKey: surfaceID)
            do {
                let receipt = try await service.updateFrontendNativeBrowserSource(
                    surfaceID: surfaceID,
                    ownerGeneration: claim.ownerGeneration,
                    requestID: update.requestID,
                    sourceURL: update.sourceURL
                )
                guard receipt.authority == claim.authority,
                      receipt.surfaceID == surfaceID,
                      receipt.ownerGeneration == claim.ownerGeneration,
                      receipt.requestID == update.requestID else {
                    failRuntimeLease(surfaceID: surfaceID)
                    return
                }
                claims[surfaceID]?.sourceURL = update.sourceURL
                if pendingSourceUpdates[surfaceID] == nil {
                    return
                }
            } catch is CancellationError {
                return
            } catch {
                failRuntimeLease(surfaceID: surfaceID)
                return
            }
        }
    }

    private func failRuntimeLease(surfaceID: SurfaceID) {
        releaseLocalState(surfaceID: surfaceID)
        failureReporter(String(
            localized: "terminalBackend.topology.disconnected",
            defaultValue: "The terminal backend connection is recovering. Existing terminals remain in the backend, but layout changes are paused until a fresh snapshot arrives."
        ))
        Task { [recoveryHandler] in
            await recoveryHandler()
        }
    }

    private func validateSourceURL(
        _ sourceURL: URL?,
        surfaceID: SurfaceID
    ) throws {
        guard let sourceURL else { return }
        guard sourceURL.absoluteString.utf8.count <= maximumSourceURLByteCount else {
            throw TerminalBackendNativeBrowserRuntimeError
                .sourceURLTooLarge(surfaceID: surfaceID)
        }
    }
}
