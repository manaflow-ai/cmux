import CmuxFoundation
import Foundation

extension CmuxTopProcessSnapshot {
    /// Builds the app-scoped process census authority at the composition root.
    /// - Parameters:
    ///   - reader: Native process reads; tests pass a synthetic reader.
    ///   - now: Monotonic clock for the service's age bounds.
    static func makeProcessSnapshotService(
        reader: any CmuxTopProcessReading = CmuxTopProcessReader(),
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) -> ProcessSnapshotService<CmuxTopProcessCapture, CmuxTopProcessFields> {
        let sampler = CmuxTopProcessSampler(reader: reader)
        // Reads of unchanged process images carry over between censuses: an idle
        // census reads one exec identity per process, not its argv/environment.
        let memo = CmuxTopProcessEnrichmentMemoStore()
        return ProcessSnapshotService(
            now: now,
            capture: { try sampler.capture() },
            enrich: { capture, fields in
                let known = await memo.current()
                let enriched = try sampler.enrich(capture, fields: fields, memo: known)
                await memo.replace(with: enriched.memo)
                return enriched.capture
            }
        )
    }

    /// Enumerates after this request. An older diagnostic census cannot authorize
    /// lifecycle decisions merely because its enrichment finished more recently.
    static func capture(
        includeProcessDetails: Bool = false,
        includeCMUXScope: Bool = true,
        includeResources: Bool = true,
        service: ProcessSnapshotService<CmuxTopProcessCapture, CmuxTopProcessFields>? = nil
    ) async -> CmuxTopProcessSnapshot {
        await capture(
            fields: CmuxTopProcessFields(details: includeProcessDetails, scope: includeCMUXScope, resources: includeResources),
            freshness: .afterRequest, service: service ?? defaultProcessSnapshotService()
        )
    }

    /// Permits diagnostic reuse only within the explicit age bound from census start.
    static func captureCached(
        includeProcessDetails: Bool = false,
        includeCMUXScope: Bool = true,
        includeResources: Bool = true,
        maximumAge: TimeInterval,
        service: ProcessSnapshotService<CmuxTopProcessCapture, CmuxTopProcessFields>? = nil
    ) async -> CmuxTopProcessSnapshot {
        await capture(
            fields: CmuxTopProcessFields(details: includeProcessDetails, scope: includeCMUXScope, resources: includeResources),
            freshness: .maximumAge(.seconds(max(0, maximumAge))), service: service ?? defaultProcessSnapshotService()
        )
    }

    private static func capture(
        fields: CmuxTopProcessFields, freshness: ProcessSnapshotFreshness,
        service: ProcessSnapshotService<CmuxTopProcessCapture, CmuxTopProcessFields>
    ) async -> CmuxTopProcessSnapshot {
        do {
            return try await service.snapshot(fields: fields, freshness: freshness).snapshot
        } catch {
            // Expiry, cancellation and admission failure are unavailable evidence,
            // never a complete empty machine. Safety callers must fail closed.
            return CmuxTopProcessSnapshot(
                processes: [], sampledAt: Date(), includesProcessDetails: fields.contains(.details),
                includesCMUXScope: fields.contains(.scope), includesResources: fields.contains(.resources),
                enumerationIsComplete: false,
                captureIsAvailable: false
            )
        }
    }

    static func allProcesses(includeProcessDetails: Bool, includeCMUXScope: Bool) async -> [CmuxTopProcessInfo] {
        let snapshot = await capture(includeProcessDetails: includeProcessDetails, includeCMUXScope: includeCMUXScope, includeResources: false)
        return Array(snapshot.processesByPID.values)
    }

    private static func defaultProcessSnapshotService() -> ProcessSnapshotService<CmuxTopProcessCapture, CmuxTopProcessFields> {
        AppDelegate.shared?.processSnapshotService ?? makeProcessSnapshotService()
    }
}
