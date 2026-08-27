import CmuxIrohTransport
import Foundation
import os

/// Address-lookup lines for the `iroh_diag` socket verb.
///
/// Same design as `MobileHostIrohRuntime+RelayDiag.swift`: a nonisolated lock
/// mirror written synchronously at installation, read without any main-actor
/// hop so the verb keeps working while the main thread is wedged. Endpoint-id
/// prefixes appear only in the local debug socket output, never in the
/// privacy-safe `DiagnosticLog` export.
extension MobileHostIrohRuntime {
    /// The installed lookup instance (nil when the flag is off or the host
    /// runtime is inactive). The instance itself owns its outcome counters
    /// behind its own lock, so this mirror only tracks installation.
    private nonisolated static let addressLookupMirror =
        OSAllocatedUnfairLock<CmxIrohRegistryAddressLookup?>(initialState: nil)

    /// The single write funnel, called where the host activation decides
    /// whether to install the lookup, before the endpoint binds.
    static func publishAddressLookupDiagMirror(
        _ lookup: CmxIrohRegistryAddressLookup?
    ) {
        addressLookupMirror.withLock { $0 = lookup }
    }

    nonisolated static func currentAddressLookup() -> CmxIrohRegistryAddressLookup? {
        addressLookupMirror.withLock { $0 }
    }

    /// The exact relay origins the address lookup may accept in resolved
    /// records: the debug override while active (every profile installation
    /// funnel substitutes it), otherwise the most recently installed
    /// effective relay policy, read through the same mirror the relay diag
    /// section prints. Mirrors the hint-dial filter in
    /// `CmxIrohLibEndpoint.endpointAddresses`.
    nonisolated static func addressLookupAllowedRelayURLs() -> Set<String> {
        if let overrideProfile = CmxIrohDebugRelayOverrideDiagnostics().activeRelayURL {
            return [overrideProfile]
        }
        return Set(currentRelayDiagState()?.relayURLs ?? [])
    }

    /// The address-lookup section appended to `iroh_diag` output.
    nonisolated static func addressLookupDiagReportText() -> String {
        addressLookupDiagReport(
            diagnostics: currentAddressLookup()?.diagnosticsSnapshot()
        )
    }

    nonisolated static func addressLookupDiagReport(
        diagnostics: CmxIrohAddressLookupDiagnostics?
    ) -> String {
        var lines = ["Address lookup (\(CmxIrohDebugAddressLookupFlag.key))"]
        guard let diagnostics else {
            lines.append("Installed: no")
            return lines.joined(separator: "\n")
        }
        lines.append("Installed: yes (since \(iso8601(diagnostics.installedAt)))")
        if let resolve = diagnostics.lastResolve {
            lines.append(
                "Last resolve: \(resolve.endpointIDPrefix)… -> "
                    + "\(resolve.source.rawValue), \(resolve.recordCount) record(s) "
                    + "at \(iso8601(resolve.at)) (\(diagnostics.resolveCount) total)"
            )
        } else {
            lines.append("Last resolve: none (\(diagnostics.resolveCount) total)")
        }
        if let publish = diagnostics.lastPublish {
            lines.append(
                "Last publish: \(publish.result.rawValue), "
                    + "\(publish.recordByteCount) bytes at \(iso8601(publish.at)) "
                    + "(\(diagnostics.publishCount) total)"
            )
        } else {
            lines.append("Last publish: none (\(diagnostics.publishCount) total)")
        }
        return lines.joined(separator: "\n")
    }

    private nonisolated static func iso8601(_ date: Date) -> String {
        date.formatted(.iso8601)
    }
}
