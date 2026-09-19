import CmuxFoundation
import Foundation

// App-target composition for this process's fixed local host/effective-user scope.
// One actor owns the census across every snapshot consumer. No data is persisted.
nonisolated let cmuxProcessSnapshots = ProcessSnapshotService<CmuxTopProcessCapture, CmuxTopProcessFields>(
    capture: { try CmuxTopProcessSampler().capture() },
    enrich: { try CmuxTopProcessSampler().enrich($0, fields: $1) }
)

extension CmuxTopProcessSnapshot {
    /// Enumerates after this request. An older diagnostic census cannot authorize
    /// lifecycle decisions merely because its enrichment finished more recently.
    static func capture(
        includeProcessDetails: Bool = false,
        includeCMUXScope: Bool = true,
        service: ProcessSnapshotService<CmuxTopProcessCapture, CmuxTopProcessFields> = cmuxProcessSnapshots
    ) async -> CmuxTopProcessSnapshot {
        await capture(
            fields: CmuxTopProcessFields(details: includeProcessDetails, scope: includeCMUXScope),
            freshness: .afterRequest, service: service
        )
    }

    /// Permits diagnostic reuse only within the explicit age bound from census start.
    static func captureCached(
        includeProcessDetails: Bool = false,
        includeCMUXScope: Bool = true,
        maximumAge: TimeInterval,
        service: ProcessSnapshotService<CmuxTopProcessCapture, CmuxTopProcessFields> = cmuxProcessSnapshots
    ) async -> CmuxTopProcessSnapshot {
        await capture(
            fields: CmuxTopProcessFields(details: includeProcessDetails, scope: includeCMUXScope),
            freshness: .maximumAge(.seconds(max(0, maximumAge))), service: service
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
                includesCMUXScope: fields.contains(.scope), enumerationIsComplete: false,
                captureIsAvailable: false
            )
        }
    }

    static func allProcesses(includeProcessDetails: Bool, includeCMUXScope: Bool) async -> [CmuxTopProcessInfo] {
        let snapshot = await capture(includeProcessDetails: includeProcessDetails, includeCMUXScope: includeCMUXScope)
        return Array(snapshot.processesByPID.values)
    }
}
