import Foundation

// MARK: - Mobile attach-ticket creation

extension TerminalController {
    @MainActor
    func v2MobileAttachTicketCreate(params: [String: Any]) async -> V2CallResult {
        let ttl = TimeInterval(max(30, min(v2Int(params, "ttl_seconds") ?? 600, 3600)))
        let routeID = v2OptionalTrimmedRawString(params, "route_id")
            ?? v2OptionalTrimmedRawString(params, "routeID")
        let routeKind = v2OptionalTrimmedRawString(params, "route_kind")
            ?? v2OptionalTrimmedRawString(params, "routeKind")
        let scope = v2OptionalTrimmedRawString(params, "scope")
        let rawTarget = v2OptionalTrimmedRawString(params, "target")
        let target: MobileAttachTarget?
        if let rawTarget {
            guard let parsed = MobileAttachTarget(wireValue: rawTarget) else {
                return .err(
                    code: "invalid_request",
                    message: "target must be ticket_only, simulator_injection, or physical_device",
                    data: ["target": rawTarget]
                )
            }
            target = parsed
        } else {
            // Preserve the pre-target contract for older control-socket callers:
            // keep the full route set and continue returning `attach_url`.
            target = nil
        }
        // scope=mac mints a Mac-wide ticket that grants access to every
        // workspace on the host. Without this, the ticket gets pinned to
        // the workspace selected at QR-generation time, and tapping any
        // other workspace from the paired iPhone falls back to Stack
        // Auth verification, which is brittle on real-world networks.
        let isMacScope = scope?.lowercased() == "mac"

        if let error = mobileWorkspaceIDValidationError(params: params) {
            return error
        }
        if let error = mobileTerminalAliasValidationError(params: params) {
            return error
        }

        let resolvedWorkspaceID: String
        let resolvedTerminalID: String?
        if isMacScope {
            resolvedWorkspaceID = ""
            resolvedTerminalID = nil
        } else {
            guard let resolved = mobileResolveWorkspaceAndSurface(params: params, requireTerminal: false) else {
                return .err(code: "not_found", message: "Workspace not found", data: nil)
            }
            let terminalPanel: TerminalPanel?
            if let surfaceId = resolved.surfaceId {
                guard let panel = resolved.workspace.terminalPanel(for: surfaceId) else {
                    return .err(
                        code: "invalid_request",
                        message: "terminal_id does not reference a terminal",
                        data: nil
                    )
                }
                terminalPanel = panel
            } else {
                terminalPanel = nil
            }
            resolvedWorkspaceID = resolved.workspace.id.uuidString
            resolvedTerminalID = terminalPanel?.id.uuidString
        }

        do {
            let payload = try await MobileHostService.shared.createAttachTicket(
                workspaceID: resolvedWorkspaceID,
                terminalID: resolvedTerminalID,
                ttl: ttl,
                routeID: routeID,
                routeKind: routeKind,
                target: target
            )
            return .ok(payload)
        } catch MobileAttachTicketStoreError.noRoutes {
            return .err(
                code: "unavailable",
                message: "Mobile host routes are not available yet",
                data: nil
            )
        } catch MobileAttachTicketStoreError.routeUnavailable {
            var data: [String: Any] = [:]
            if let routeID {
                data["route_id"] = routeID
            }
            if let routeKind {
                data["route_kind"] = routeKind
            }
            return .err(
                code: "unavailable",
                message: "Requested mobile host route is not available",
                data: data.isEmpty ? nil : data
            )
        } catch MobileAttachTicketStoreError.invalidAttachURL {
            return .err(
                code: "unavailable",
                message: "Selected mobile host routes cannot be represented for the requested target",
                data: ["target": target?.rawValue ?? "legacy"]
            )
        } catch {
            return .err(
                code: "internal_error",
                message: "Failed to create mobile attach ticket",
                data: ["error": String(describing: error)]
            )
        }
    }
}
