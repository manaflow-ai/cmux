import AppKit
import CmuxFoundation
import CoreGraphics
import Foundation

extension TerminalController {
    /// Socket-worker router for `window.record.*`.
    ///
    /// These block their worker thread while ScreenCaptureKit answers, so the
    /// execution policy keeps them off the main actor (see
    /// `ControlCommandExecutionPolicy`).
    nonisolated func v2WindowRecordingCommandOnSocketWorker(
        method: String,
        params: [String: Any]
    ) -> V2CallResult {
        switch method {
        case "window.record.start":
            return v2WindowRecordStart(params: params)
        case "window.record.stop":
            return v2WindowRecordStop(params: params)
        case "window.record.status":
            return v2WindowRecordStatus(params: params)
        case "window.record.note":
            return v2WindowRecordNote(params: params)
        case "window.record.list":
            return v2WindowRecordList()
        default:
            return .err(
                code: "unknown_method",
                message: "Unknown method \(method)",
                data: nil
            )
        }
    }

    private nonisolated func v2WindowRecordStart(params: [String: Any]) -> V2CallResult {
        let request: WindowRecordingRequest
        do {
            request = try WindowRecordingRequest.make(params: params)
        } catch let failure as WindowRecordingRequest.Failure {
            return .err(code: "invalid_params", message: failure.message, data: nil)
        } catch {
            return .err(code: "invalid_params", message: error.localizedDescription, data: nil)
        }
        guard let windowID = recordingWindowID(handle: request.windowHandle) else {
            return .err(
                code: "not_found",
                message: request.windowHandle.map { "Window \($0) is not available" }
                    ?? "No window available",
                data: nil
            )
        }
        let token = UUID()
        return awaitRecordingCall(
            timeout: 20,
            onTimeout: {
                await WindowRecordingRegistry.shared.abandonStart(token: token)
            }
        ) {
            try await WindowRecordingRegistry.shared.start(
                request: request,
                windowID: windowID,
                windowHandle: request.windowHandle,
                token: token
            )
        }
    }

    private nonisolated func v2WindowRecordStop(params: [String: Any]) -> V2CallResult {
        let id = (params["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return awaitRecordingCall(timeout: 30) {
            try await WindowRecordingRegistry.shared.stop(id: id?.isEmpty == false ? id : nil)
        }
    }

    private nonisolated func v2WindowRecordStatus(params: [String: Any]) -> V2CallResult {
        let id = (params["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return awaitRecordingCall(timeout: 10) {
            try await WindowRecordingRegistry.shared.status(id: id?.isEmpty == false ? id : nil)
        }
    }

    private nonisolated func v2WindowRecordNote(params: [String: Any]) -> V2CallResult {
        let id = (params["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = (params["text"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            return .err(code: "invalid_params", message: "text is required", data: nil)
        }
        return awaitRecordingCall(timeout: 10) {
            try await WindowRecordingRegistry.shared.note(
                text: text,
                id: id?.isEmpty == false ? id : nil
            )
        }
    }

    private nonisolated func v2WindowRecordList() -> V2CallResult {
        let statuses: [WindowRecordingStatus]? = socketAwaitCallback(timeout: 10) { completion in
            Task {
                completion(await WindowRecordingRegistry.shared.recentStatuses())
            }
        }
        guard let statuses else {
            return .err(code: "timeout", message: "window.record.list timed out", data: nil)
        }
        return .ok(["recordings": statuses.map { $0.jsonObject }])
    }

    /// Resolves the window to film: the one named by `window`, else the
    /// frontmost cmux window.
    private nonisolated func recordingWindowID(handle: String?) -> CGWindowID? {
        v2MainSync {
            let eligibleWindows = WindowRecordingWindowSelection.eligibleWindows(in: NSApp)
            let selected: NSWindow?
            if let handle {
                guard let windowId = UUID(uuidString: handle),
                      let requested = AppDelegate.shared?.mainWindow(for: windowId),
                      eligibleWindows.contains(where: { $0 === requested }) else {
                    return nil
                }
                selected = requested
            } else {
                selected = WindowRecordingWindowSelection.select(
                    eligibleWindows: eligibleWindows,
                    keyWindow: NSApp.keyWindow,
                    mainWindow: NSApp.mainWindow,
                    terminalWindow: self.tabManager?.window
                )
            }
            guard let selected else { return nil }
            return WindowRecordingWindowSelection.windowID(
                fromWindowNumber: selected.windowNumber
            )
        }
    }

    private nonisolated func awaitRecordingCall(
        timeout: TimeInterval,
        onTimeout: (@Sendable () async -> Void)? = nil,
        _ work: @escaping () async throws -> WindowRecordingStatus
    ) -> V2CallResult {
        let outcome: Result<WindowRecordingStatus, Error>? = socketAwaitCallback(
            timeout: timeout
        ) { completion in
            Task {
                do {
                    completion(.success(try await work()))
                } catch {
                    completion(.failure(error))
                }
            }
        }
        guard let outcome else {
            // The work keeps running after the wait gives up. Let the caller
            // undo it before answering, so a "timeout" reply never leaves
            // behind the side effect it reports as failed.
            if let onTimeout {
                let _: Void? = socketAwaitCallback(timeout: 10) { completion in
                    Task {
                        await onTimeout()
                        completion(())
                    }
                }
            }
            return .err(
                code: "timeout",
                message: "recording command timed out after \(Int(timeout)) seconds",
                data: nil
            )
        }
        switch outcome {
        case let .success(status):
            return .ok(status.jsonObject)
        case let .failure(error):
            return .err(
                code: Self.recordingErrorCode(for: error),
                message: error.localizedDescription,
                data: nil
            )
        }
    }

    /// Maps a recorder error onto the socket error code the caller sees.
    ///
    /// Internal rather than private so a test can pin every case: the codes are
    /// what a CLI or a tour branches on, and "a recording is already running"
    /// has to stay distinguishable from "your output path is wrong".
    nonisolated static func recordingErrorCode(for error: Error) -> String {
        if let failure = error as? WindowRecordingRegistry.Failure {
            switch failure {
            case .busy:
                return "conflict"
            case .noRecording, .unknownRecording, .alreadyStopped:
                return "not_found"
            }
        }
        if let failure = error as? WindowRecordingSessionError {
            switch failure {
            case .unsupportedSystem:
                return "unsupported"
            case .windowGone:
                return "not_found"
            case .outputNotAFile:
                // The caller's `out` names something that is not a file the
                // recorder may replace, so this is their parameter, not our bug.
                return "invalid_params"
            case .captureFailed, .composeFailed, .alreadyFinished:
                return "internal_error"
            }
        }
        if error is WindowRecordingFrameGeometry.Failure {
            return "invalid_params"
        }
        return "internal_error"
    }
}
