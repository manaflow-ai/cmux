import CmuxFoundation
import Foundation

extension CmuxTopProcessSnapshot {
    /// Builds the app-scoped process census authority at the composition root.
    static func makeProcessSnapshotService() -> ProcessSnapshotService<CmuxTopProcessCapture, CmuxTopProcessFields> {
        ProcessSnapshotService(
            capture: { try CmuxTopProcessSampler().capture() },
            enrich: { try CmuxTopProcessSampler().enrich($0, fields: $1) }
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
