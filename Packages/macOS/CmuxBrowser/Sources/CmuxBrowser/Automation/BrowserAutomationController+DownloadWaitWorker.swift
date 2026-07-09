import Foundation

extension BrowserAutomationController {
    /// Serves the `browser.download.wait` command on the socket-worker lane,
    /// byte-faithful relocation of the legacy `v2BrowserDownloadWaitOnSocketWorker`:
    /// resolves the worker timeout budget, the optional destination `path`, and the
    /// app-side context snapshot (through the host seam), then either waits for the
    /// destination file to become non-empty (``BrowserDownloadFileWaiter``), returns
    /// an already-queued download event, or blocks on the captured download-event
    /// wait (``waitForDownloadEvent(surfaceId:timeout:)``).
    ///
    /// `nonisolated`: runs on the calling socket-worker thread; the only main-actor
    /// work (workspace/surface resolution, ref minting, the queued-event pop) stays
    /// inside the host's ``BrowserControlHosting/resolveBrowserDownloadWaitSnapshot(params:)``
    /// witness, which performs its own main hop.
    public nonisolated func downloadWaitOnSocketWorker(
        params: [String: Any],
        host: any BrowserControlHosting
    ) -> BrowserCommandResult {
        let requestedTimeoutMs = max(
            1,
            Self.downloadWaitInt(params, "timeout_ms") ??
                Self.downloadWaitInt(params, "timeout") ??
                Self.downloadWaitDefaultTimeoutMs
        )
        let timeoutMs = min(requestedTimeoutMs, Self.downloadWaitMaxTimeoutMs)
        let timeout = Double(timeoutMs) / 1000.0
        let path = Self.downloadWaitString(params, "path")

        let snapshot = host.resolveBrowserDownloadWaitSnapshot(params: params)
        if let error = snapshot.error {
            return error
        }

        if let path {
            switch BrowserDownloadFileWaiter().wait(forDownloadAt: path, timeout: timeout) {
            case .ready:
                break
            case .timeout:
                return .err(
                    code: "timeout",
                    message: "Timed out waiting for download file",
                    data: [
                        "path": path,
                        "timeout_ms": timeoutMs,
                        "requested_timeout_ms": requestedTimeoutMs
                    ]
                )
            case .watcherSetupFailed(let errnoCode):
                return .err(
                    code: "internal_error",
                    message: "Failed to watch download path",
                    data: ["path": path, "errno": Int(errnoCode)]
                )
            }
            return .ok([
                "workspace_id": snapshot.workspaceId.uuidString,
                "workspace_ref": snapshot.workspaceRef,
                "surface_id": snapshot.surfaceId.uuidString,
                "surface_ref": snapshot.surfaceRef,
                "path": path,
                "downloaded": true
            ])
        }

        if let queuedEvent = snapshot.queuedEvent {
            return .ok([
                "workspace_id": snapshot.workspaceId.uuidString,
                "workspace_ref": snapshot.workspaceRef,
                "surface_id": snapshot.surfaceId.uuidString,
                "surface_ref": snapshot.surfaceRef,
                "download": queuedEvent
            ])
        }

        guard let downloadEvent = waitForDownloadEvent(surfaceId: snapshot.surfaceId, timeout: timeout) else {
            return .err(
                code: "timeout",
                message: "No download event observed",
                data: [
                    "timeout_ms": timeoutMs,
                    "requested_timeout_ms": requestedTimeoutMs
                ]
            )
        }
        return .ok([
            "workspace_id": snapshot.workspaceId.uuidString,
            "workspace_ref": snapshot.workspaceRef,
            "surface_id": snapshot.surfaceId.uuidString,
            "surface_ref": snapshot.surfaceRef,
            "download": downloadEvent
        ])
    }

    /// The trimmed non-empty string param at `key` (byte-faithful twin of the
    /// legacy worker-lane `v2WorkerString`: whitespace-only is treated as absent).
    /// `public` so the host's download-wait snapshot witness shares this one parser
    /// when deciding whether a `path` was requested.
    public nonisolated static func downloadWaitString(_ params: [String: Any], _ key: String) -> String? {
        guard let raw = params[key] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The integer param at `key` (byte-faithful twin of the legacy worker-lane
    /// `v2WorkerInt`: an `Int`, a boxed `NSNumber`, or a trimmed parseable string).
    nonisolated static func downloadWaitInt(_ params: [String: Any], _ key: String) -> Int? {
        if let intValue = params[key] as? Int {
            return intValue
        }
        if let number = params[key] as? NSNumber {
            return number.intValue
        }
        if let raw = downloadWaitString(params, key) {
            return Int(raw)
        }
        return nil
    }
}
