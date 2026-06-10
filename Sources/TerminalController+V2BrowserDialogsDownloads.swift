import AppKit
import CmuxAuthRuntime
import CmuxControlSocket
import CmuxSettings
import CmuxSocketControl
import CmuxSwiftRenderUI
import Carbon.HIToolbox
import CMUXMobileCore
import CMUXWorkstream
import Foundation
import Bonsplit
import WebKit


// MARK: - V2 browser frames, dialogs, and downloads
extension TerminalController {
    func v2BrowserFrameSelect(params: [String: Any]) -> V2CallResult {
        guard let selectorRaw = v2BrowserSelector(params) else {
            return .err(code: "invalid_params", message: "Missing selector", data: nil)
        }

        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            guard let selector = v2BrowserResolveSelector(selectorRaw, surfaceId: surfaceId) else {
                return .err(code: "not_found", message: "Element reference not found", data: ["selector": selectorRaw])
            }
            let selectorLiteral = v2JSONLiteral(selector)
            let script = """
            (() => {
              const frame = document.querySelector(\(selectorLiteral));
              if (!frame) return { ok: false, error: 'not_found' };
              if (!('contentDocument' in frame)) return { ok: false, error: 'not_frame' };
              try {
                const sameOrigin = !!frame.contentDocument;
                if (!sameOrigin) return { ok: false, error: 'cross_origin' };
              } catch (_) {
                return { ok: false, error: 'cross_origin' };
              }
              return { ok: true };
            })()
            """
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                if let dict = value as? [String: Any],
                   let ok = dict["ok"] as? Bool,
                   ok {
                    v2BrowserFrameSelectorBySurface[surfaceId] = selector
                    return .ok([
                        "workspace_id": ws.id.uuidString,
                        "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                        "surface_id": surfaceId.uuidString,
                        "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                        "frame_selector": selector
                    ])
                }
                if let dict = value as? [String: Any],
                   let errorText = dict["error"] as? String,
                   errorText == "cross_origin" {
                    return .err(code: "not_supported", message: "Cross-origin iframe control is not supported", data: ["selector": selector])
                }
                return .err(code: "not_found", message: "Frame not found", data: ["selector": selector])
            }
        }
    }

    func v2BrowserFrameMain(params: [String: Any]) -> V2CallResult {
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, _ in
            v2BrowserFrameSelectorBySurface.removeValue(forKey: surfaceId)
            return .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "frame_selector": NSNull()
            ])
        }
    }

    func v2BrowserEnsureTelemetryHooks(surfaceId _: UUID, browserPanel: BrowserPanel) {
        _ = v2RunJavaScript(
            browserPanel.webView,
            script: BrowserPanel.telemetryHookBootstrapScriptSource,
            timeout: 5.0,
            contentWorld: .page
        )
    }

    private func v2BrowserEnsureDialogHooks(browserPanel: BrowserPanel) {
        _ = v2RunJavaScript(
            browserPanel.webView,
            script: BrowserPanel.dialogTelemetryHookBootstrapScriptSource,
            timeout: 5.0,
            contentWorld: .page
        )
    }

    func v2BrowserDialogRespond(params: [String: Any], accept: Bool) -> V2CallResult {
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            v2BrowserEnsureTelemetryHooks(surfaceId: surfaceId, browserPanel: browserPanel)
            v2BrowserEnsureDialogHooks(browserPanel: browserPanel)
            let text = v2String(params, "text") ?? v2String(params, "prompt_text")
            let acceptLiteral = accept ? "true" : "false"
            let textLiteral = text.map(v2JSONLiteral) ?? "null"
            let script = """
            (() => {
              const q = window.__cmuxDialogQueue || [];
              if (!q.length) return { ok: false, error: 'not_found' };
              const entry = q.shift();
              if (entry.type === 'confirm') {
                window.__cmuxDialogDefaults = window.__cmuxDialogDefaults || { confirm: false, prompt: null };
                window.__cmuxDialogDefaults.confirm = \(acceptLiteral);
              }
              if (entry.type === 'prompt') {
                window.__cmuxDialogDefaults = window.__cmuxDialogDefaults || { confirm: false, prompt: null };
                if (\(acceptLiteral)) {
                  window.__cmuxDialogDefaults.prompt = \(textLiteral);
                } else {
                  window.__cmuxDialogDefaults.prompt = null;
                }
              }
              return { ok: true, dialog: entry, remaining: q.length };
            })()
            """

            switch v2RunJavaScript(browserPanel.webView, script: script, timeout: 5.0, contentWorld: .page) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                guard let dict = value as? [String: Any],
                      let ok = dict["ok"] as? Bool,
                      ok else {
                    let pending = v2BrowserPendingDialogs(surfaceId: surfaceId)
                    return .err(code: "not_found", message: "No pending dialog", data: ["pending": pending])
                }

                return .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "accepted": accept,
                    "dialog": v2NormalizeJSValue(dict["dialog"]),
                    "remaining": v2OrNull(dict["remaining"])
                ])
            }
        }
    }

    private struct V2BrowserDownloadWaitSnapshot {
        let workspaceId: UUID
        let workspaceRef: Any
        let surfaceId: UUID
        let surfaceRef: Any
        let queuedEvent: [String: Any]?
        let error: V2CallResult?
    }

    private enum V2DownloadFileWaitResult: Sendable {
        case ready
        case timeout
        case watcherSetupFailed(errnoCode: Int32)
    }

    nonisolated func v2BrowserDownloadWaitOnSocketWorker(params: [String: Any]) -> V2CallResult {
        let requestedTimeoutMs = max(
            1,
            Self.v2WorkerInt(params, "timeout_ms") ??
                Self.v2WorkerInt(params, "timeout") ??
                Self.v2BrowserDownloadWaitDefaultTimeoutMs
        )
        let timeoutMs = min(requestedTimeoutMs, Self.v2BrowserDownloadWaitMaxTimeoutMs)
        let timeout = Double(timeoutMs) / 1000.0
        let path = Self.v2WorkerString(params, "path")

        let snapshot = v2BrowserDownloadWaitSnapshot(params: params)
        if let error = snapshot.error {
            return error
        }

        if let path {
            switch v2WaitForDownloadFile(path: path, timeout: timeout) {
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

        guard let downloadEvent = v2WaitForDownloadEvent(surfaceId: snapshot.surfaceId, timeout: timeout) else {
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

    private nonisolated static func v2WorkerString(_ params: [String: Any], _ key: String) -> String? {
        guard let raw = params[key] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private nonisolated static func v2WorkerInt(_ params: [String: Any], _ key: String) -> Int? {
        if let intValue = params[key] as? Int {
            return intValue
        }
        if let number = params[key] as? NSNumber {
            return number.intValue
        }
        if let raw = v2WorkerString(params, key) {
            return Int(raw)
        }
        return nil
    }

    private nonisolated func v2BrowserDownloadWaitSnapshot(params: [String: Any]) -> V2BrowserDownloadWaitSnapshot {
        v2MainSync {
            v2RefreshKnownRefs()
            guard let tabManager = v2ResolveTabManager(params: params) else {
                return V2BrowserDownloadWaitSnapshot(
                    workspaceId: UUID(),
                    workspaceRef: NSNull(),
                    surfaceId: UUID(),
                    surfaceRef: NSNull(),
                    queuedEvent: nil,
                    error: .err(code: "unavailable", message: "TabManager not available", data: nil)
                )
            }
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                return V2BrowserDownloadWaitSnapshot(
                    workspaceId: UUID(),
                    workspaceRef: NSNull(),
                    surfaceId: UUID(),
                    surfaceRef: NSNull(),
                    queuedEvent: nil,
                    error: .err(code: "not_found", message: "Workspace not found", data: nil)
                )
            }
            let resolvedSurface = v2ResolveBrowserSurfaceId(params: params, workspace: ws)
            if let error = resolvedSurface.error {
                return V2BrowserDownloadWaitSnapshot(
                    workspaceId: ws.id,
                    workspaceRef: v2Ref(kind: .workspace, uuid: ws.id),
                    surfaceId: UUID(),
                    surfaceRef: NSNull(),
                    queuedEvent: nil,
                    error: error
                )
            }
            let surfaceId = resolvedSurface.surfaceId
            guard let surfaceId else {
                return V2BrowserDownloadWaitSnapshot(
                    workspaceId: ws.id,
                    workspaceRef: v2Ref(kind: .workspace, uuid: ws.id),
                    surfaceId: UUID(),
                    surfaceRef: NSNull(),
                    queuedEvent: nil,
                    error: .err(code: "not_found", message: "No focused browser surface", data: nil)
                )
            }
            guard ws.browserPanel(for: surfaceId) != nil else {
                return V2BrowserDownloadWaitSnapshot(
                    workspaceId: ws.id,
                    workspaceRef: v2Ref(kind: .workspace, uuid: ws.id),
                    surfaceId: surfaceId,
                    surfaceRef: v2Ref(kind: .surface, uuid: surfaceId),
                    queuedEvent: nil,
                    error: .err(code: "invalid_params", message: "Surface is not a browser", data: ["surface_id": surfaceId.uuidString])
                )
            }

            return V2BrowserDownloadWaitSnapshot(
                workspaceId: ws.id,
                workspaceRef: v2Ref(kind: .workspace, uuid: ws.id),
                surfaceId: surfaceId,
                surfaceRef: v2Ref(kind: .surface, uuid: surfaceId),
                queuedEvent: Self.v2WorkerString(params, "path") == nil
                    ? v2PopBrowserDownloadEvent(surfaceId: surfaceId)
                    : nil,
                error: nil
            )
        }
    }

    private func v2PopBrowserDownloadEvent(surfaceId: UUID) -> [String: Any]? {
        guard let first = v2BrowserDownloadEventsBySurface[surfaceId]?.first else {
            return nil
        }
        var remaining = v2BrowserDownloadEventsBySurface[surfaceId] ?? []
        remaining.removeFirst()
        v2BrowserDownloadEventsBySurface[surfaceId] = remaining
        return first
    }

    private nonisolated func v2WaitForDownloadFile(path: String, timeout: TimeInterval) -> V2DownloadFileWaitResult {
        let fm = FileManager.default
        let pathIsReady = {
            guard fm.fileExists(atPath: path),
                  let attrs = try? fm.attributesOfItem(atPath: path),
                  let size = attrs[.size] as? NSNumber else {
                return false
            }
            return size.intValue > 0
        }
        if pathIsReady() {
            return .ready
        }

        let watchedPath = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let fd = open(watchedPath, O_EVTONLY)
        guard fd >= 0 else {
            return .watcherSetupFailed(errnoCode: errno)
        }

        let lock = NSLock()
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var finished = false
        nonisolated(unsafe) var ready = false
        let finishOnce: (Bool) -> Void = { value in
            lock.lock()
            guard !finished else {
                lock.unlock()
                return
            }
            finished = true
            ready = value
            lock.unlock()
            semaphore.signal()
        }

        let watcherQueue = DispatchQueue(label: "com.cmux.browser.download.wait.file")
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib, .link, .rename],
            queue: watcherQueue
        )
        source.setEventHandler {
            if pathIsReady() {
                finishOnce(true)
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        if pathIsReady() {
            finishOnce(true)
        }
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            finishOnce(pathIsReady())
        }
        source.cancel()
        return ready ? .ready : .timeout
    }

    private nonisolated func v2WaitForDownloadEvent(surfaceId: UUID, timeout: TimeInterval) -> [String: Any]? {
        let lock = NSLock()
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var finished = false
        nonisolated(unsafe) var event: [String: Any]?
        var observer: NSObjectProtocol?

        let finishOnce: ([String: Any]?) -> Void = { value in
            lock.lock()
            guard !finished else {
                lock.unlock()
                return
            }
            finished = true
            event = value
            lock.unlock()
            semaphore.signal()
        }

        observer = NotificationCenter.default.addObserver(
            forName: .browserDownloadEventDidArrive,
            object: nil,
            queue: nil
        ) { note in
            guard let candidateSurfaceId = note.userInfo?["surfaceId"] as? UUID,
                  candidateSurfaceId == surfaceId,
                  let event = note.userInfo?["event"] as? [String: Any] else {
                return
            }
            finishOnce(event)
        }

        if let queued = v2MainSync({ v2PopBrowserDownloadEvent(surfaceId: surfaceId) }) {
            finishOnce(queued)
        }
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            finishOnce(nil)
        }
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        return event
    }

    func v2BrowserImportDialog(params: [String: Any]) -> V2CallResult {
        let scope: BrowserImportScope?
        if params.keys.contains("scope") {
            guard let raw = v2String(params, "scope")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !raw.isEmpty else {
                return .err(code: "invalid_params", message: "scope must be a non-empty string", data: ["param": "scope"])
            }
            switch raw {
            case "cookie", "cookies", "cookiesonly", "cookies_only", "cookies-only":
                scope = .cookiesOnly
            case "history", "historyonly", "history_only", "history-only":
                scope = .historyOnly
            case "cookiesandhistory", "cookies_and_history", "cookies-and-history", "all-basic":
                scope = .cookiesAndHistory
            case "everything", "all":
                scope = .everything
            default:
                return .err(code: "invalid_params", message: "scope is invalid", data: ["param": "scope"])
            }
        } else {
            scope = nil
        }

        let defaultDestinationProfileID: UUID?
        if params.keys.contains("destination_profile") {
            guard let query = v2String(params, "destination_profile")?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !query.isEmpty else {
                return .err(
                    code: "invalid_params",
                    message: "destination_profile must be a non-empty string",
                    data: ["param": "destination_profile"]
                )
            }
            let profiles = BrowserProfileStore.shared.profiles
            if let uuid = UUID(uuidString: query),
               profiles.contains(where: { $0.id == uuid }) {
                defaultDestinationProfileID = uuid
            } else if let profile = profiles.first(where: {
                $0.displayName.localizedCaseInsensitiveCompare(query) == .orderedSame ||
                    $0.slug.localizedCaseInsensitiveCompare(query) == .orderedSame
            }) {
                defaultDestinationProfileID = profile.id
            } else if v2Bool(params, "create_destination_profile") == true ||
                v2Bool(params, "create_profile") == true {
                guard let createdProfileID = BrowserProfileStore.shared.createProfile(named: query)?.id else {
                    return .err(
                        code: "invalid_params",
                        message: "destination_profile could not be created",
                        data: ["param": "destination_profile"]
                    )
                }
                defaultDestinationProfileID = createdProfileID
            } else {
                return .err(
                    code: "invalid_params",
                    message: "destination_profile does not match a cmux browser profile",
                    data: ["param": "destination_profile"]
                )
            }
        } else {
            defaultDestinationProfileID = nil
        }
        Task { @MainActor in
            BrowserDataImportCoordinator.shared.presentImportDialog(
                defaultDestinationProfileID: defaultDestinationProfileID,
                defaultScope: scope
            )
        }
        return .ok([
            "opened": true,
            "scope": scope.map { $0.rawValue as Any } ?? NSNull(),
        ])
    }

}
