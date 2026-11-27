import Foundation

extension TerminalController {
    // Keep the CLI bound aligned with BrowserPanel's 25-record popover retention.
    private nonisolated static let v2BrowserDownloadListMaxLimit = 25

    private struct V2BrowserDownloadListEntry {
        let id: String
        let filename: String
        let path: String?
        let status: String
        let byteCount: Int?
    }

    /// Returns a bounded, non-consuming snapshot of one browser surface's
    /// downloads. The snapshot reads ``BrowserPanel.recentDownloads`` so it
    /// stays in lockstep with the Downloads popover and survives waiters that
    /// consume the separate event queue.
    nonisolated func v2BrowserDownloadListOnSocketWorker(
        params: [String: Any]
    ) -> V2CallResult {
        let limit: Int
        if let rawLimit = params["limit"] {
            if (rawLimit as? NSNumber).map({ CFGetTypeID($0) == CFBooleanGetTypeID() }) == true {
                return .err(
                    code: "invalid_params",
                    message: "limit must be an integer between 1 and \(Self.v2BrowserDownloadListMaxLimit)",
                    data: ["limit": rawLimit]
                )
            } else if let value = rawLimit as? Int {
                limit = value
            } else if let value = rawLimit as? NSNumber,
                      value.doubleValue.isFinite,
                      value.doubleValue.rounded() == value.doubleValue,
                      value.doubleValue >= Double(Int.min),
                      value.doubleValue <= Double(Int.max) {
                limit = value.intValue
            } else if let value = rawLimit as? String, let parsed = Int(value) {
                limit = parsed
            } else {
                return .err(
                    code: "invalid_params",
                    message: "limit must be an integer between 1 and \(Self.v2BrowserDownloadListMaxLimit)",
                    data: ["limit": rawLimit]
                )
            }
        } else {
            limit = Self.v2BrowserDownloadListMaxLimit
        }
        guard (1...Self.v2BrowserDownloadListMaxLimit).contains(limit) else {
            return .err(
                code: "invalid_params",
                message: "limit must be an integer between 1 and \(Self.v2BrowserDownloadListMaxLimit)",
                data: ["limit": limit]
            )
        }

        let resolution: (
            snapshot: (workspaceId: UUID, workspaceRef: Any, surfaceId: UUID, surfaceRef: Any, entries: [V2BrowserDownloadListEntry])?,
            error: V2CallResult?
        ) = v2MainSync(commandKey: "browser.download.list") {
            v2RefreshKnownRefs()
            guard let tabManager = v2ResolveTabManager(params: params) else {
                return (snapshot: nil, error: .err(code: "unavailable", message: "TabManager not available", data: nil))
            }
            let resolved = v2ResolveBrowserPanelContext(params: params, tabManager: tabManager)
            if let error = resolved.error {
                return (snapshot: nil, error: error)
            }
            guard let context = resolved.context else {
                return (snapshot: nil, error: .err(code: "internal_error", message: "Browser operation failed", data: nil))
            }

            let entries = context.browserPanel.recentDownloads
                .prefix(limit)
                .map { record in
                    let status: String
                    switch record.state {
                    case .downloading:
                        status = "downloading"
                    case .saved:
                        status = "saved"
                    case .failed:
                        status = "failed"
                    }
                    return V2BrowserDownloadListEntry(
                        id: record.id,
                        filename: record.filename,
                        path: record.fileURL?.path,
                        status: status,
                        byteCount: record.byteCount
                    )
                }
            return (
                snapshot: (
                    workspaceId: context.workspaceId,
                    workspaceRef: v2Ref(kind: .workspace, uuid: context.workspaceId),
                    surfaceId: context.surfaceId,
                    surfaceRef: v2Ref(kind: .surface, uuid: context.surfaceId),
                    entries: entries
                ),
                error: nil
            )
        }

        if let error = resolution.error {
            return error
        }
        guard let snapshot = resolution.snapshot else {
            return .err(code: "internal_error", message: "Browser operation failed", data: nil)
        }
        let downloads = snapshot.entries.map(v2BrowserDownloadListPayload)
        return .ok([
            "workspace_id": snapshot.workspaceId.uuidString,
            "workspace_ref": snapshot.workspaceRef,
            "surface_id": snapshot.surfaceId.uuidString,
            "surface_ref": snapshot.surfaceRef,
            "downloads": downloads,
            "count": downloads.count,
            "limit": limit,
        ])
    }

    private nonisolated func v2BrowserDownloadListPayload(
        _ entry: V2BrowserDownloadListEntry
    ) -> [String: Any] {
        let path = entry.path
        return [
            "download_id": entry.id,
            "filename": entry.filename,
            "path": path ?? NSNull(),
            "path_exists": path.map { FileManager.default.fileExists(atPath: $0) } ?? NSNull(),
            "status": entry.status,
            "bytes": entry.byteCount.map { $0 } ?? NSNull(),
        ]
    }
}
