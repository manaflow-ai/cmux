import AppKit
import Foundation

#if DEBUG
extension TerminalController {
    /// `debug.window.record {action: "start"|"stop", path?}`: records cmux's main window
    /// only, for frame-by-frame animation checks. Runs on the socket worker; the window
    /// lookup hops to the main actor. Never activates the app or changes focus.
    nonisolated func debugWindowRecord(_ request: V2SocketRequest) -> String {
        let action = (request.params["action"] as? String) ?? ""
        switch action {
        case "start":
            guard let path = request.params["path"] as? String, path.hasPrefix("/") else {
                return v2Error(id: request.id, code: "invalid_params", message: "start needs an absolute path")
            }
            let windowID: CGWindowID? = v2MainSync {
                let window = self.tabManager?.window ?? NSApp.mainWindow ?? NSApp.keyWindow
                guard let window, window.windowNumber > 0 else { return nil }
                return CGWindowID(window.windowNumber)
            }
            guard let windowID else {
                return v2Error(id: request.id, code: "not_found", message: "No window available")
            }
            let recorder = debugWindowRecorder
            let outcome: Result<Void, any Error>? = socketAwaitCallback(timeout: 10) { completion in
                Task {
                    do {
                        try await recorder.start(windowID: windowID, url: URL(fileURLWithPath: path))
                        completion(.success(()))
                    } catch {
                        completion(.failure(error))
                    }
                }
            }
            switch outcome {
            case .success?:
                return v2Ok(id: request.id, result: ["recording": true, "path": path, "window_id": Int(windowID)])
            case .failure(let error)?:
                return v2Error(id: request.id, code: "internal_error", message: String(describing: error))
            case nil:
                return v2Error(id: request.id, code: "timeout", message: "recording did not start")
            }
        case "stop":
            let recorder = debugWindowRecorder
            let outcome: Result<String, any Error>? = socketAwaitCallback(timeout: 20) { completion in
                Task {
                    do {
                        completion(.success(try await recorder.stop()))
                    } catch {
                        completion(.failure(error))
                    }
                }
            }
            switch outcome {
            case .success(let path)?:
                return v2Ok(id: request.id, result: ["recording": false, "path": path])
            case .failure(let error)?:
                return v2Error(id: request.id, code: "internal_error", message: String(describing: error))
            case nil:
                return v2Error(id: request.id, code: "timeout", message: "recording did not finalize")
            }
        default:
            return v2Error(id: request.id, code: "invalid_params", message: "action must be start or stop")
        }
    }

    /// `debug.agent_chat.action {action: "scroll_top"|"jump_latest"|"toggle_last_group"}`:
    /// drives the focused agent chat pane for scripted animation recordings. Does not
    /// change focus.
    nonisolated func debugAgentChatAction(_ request: V2SocketRequest) -> String {
        let action = (request.params["action"] as? String) ?? ""
        let handled: Bool = v2MainSync {
            guard let workspace = self.tabManager?.selectedWorkspace,
                  let panelID = workspace.focusedPanelId,
                  let panel = workspace.panels[panelID] as? AgentSessionPanel else { return false }
            return panel.performDebugChatAction(action)
        }
        guard handled else {
            return v2Error(id: request.id, code: "not_found", message: "no focused agent chat pane handled \(action)")
        }
        return v2Ok(id: request.id, result: ["action": action])
    }
}
#endif
