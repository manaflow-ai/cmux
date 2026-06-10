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


// MARK: - V2 feed and app focus methods
extension TerminalController {
    nonisolated func v2FeedPush(params: [String: Any]) -> V2CallResult {
        let waitTimeout: TimeInterval
        if let rawTimeout = params["wait_timeout_seconds"] {
            let seconds: Double?
            if let number = rawTimeout as? NSNumber {
                seconds = number.doubleValue
            } else if let value = rawTimeout as? Double {
                seconds = value
            } else if let value = rawTimeout as? Int {
                seconds = Double(value)
            } else {
                seconds = nil
            }
            guard let seconds else {
                return .err(
                    code: "invalid_params",
                    message: "feed.push wait_timeout_seconds must be numeric",
                    data: nil
                )
            }
            guard seconds.isFinite, seconds >= 0, seconds <= 120 else {
                return .err(
                    code: "invalid_params",
                    message: "feed.push wait_timeout_seconds must be between 0 and 120",
                    data: nil
                )
            }
            waitTimeout = seconds
        } else {
            waitTimeout = 0
        }
        let eventDict: [String: Any]
        if let nested = params["event"] as? [String: Any] {
            eventDict = nested
        } else if params["session_id"] != nil,
                  params["hook_event_name"] != nil,
                  params["_source"] != nil {
            eventDict = params
        } else {
            return .err(
                code: "invalid_params",
                message: "feed.push requires an `event` object",
                data: nil
            )
        }

        let event: WorkstreamEvent
        do {
            let data = try JSONSerialization.data(withJSONObject: eventDict)
            event = try JSONDecoder().decode(WorkstreamEvent.self, from: data)
        } catch {
            return .err(
                code: "invalid_params",
                message: "feed.push event failed to decode: \(error)",
                data: nil
            )
        }

        CmuxEventBus.shared.publishWorkstreamEvent(event, phase: "received")
        v2ApplyIMessageModeSideEffects(for: event)

        let result = FeedCoordinator.shared.ingestBlocking(
            event: event,
            waitTimeout: waitTimeout
        )
        CmuxEventBus.shared.publishWorkstreamEvent(
            event,
            phase: "completed",
            result: FeedSocketEncoding.payload(for: result)
        )
        return .ok(FeedSocketEncoding.payload(for: result))
    }

    private nonisolated func v2ApplyIMessageModeSideEffects(for event: WorkstreamEvent) {
        guard event.hookEventName == .userPromptSubmit || event.hookEventName == .stop || event.hookEventName == .subagentStop,
              let rawWorkspaceId = event.workspaceId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawWorkspaceId.isEmpty
        else { return }

        let iMessageModeEnabled = IMessageModeSettings.isEnabled()
        switch event.hookEventName {
        case .userPromptSubmit:
            v2MainSync {
                guard let workspaceId = v2UUIDAny(rawWorkspaceId) else { return }
                guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: workspaceId) else { return }
                _ = tabManager.handlePromptSubmit(
                    workspaceId: workspaceId,
                    message: event.submittedPromptMessage,
                    iMessageModeEnabled: iMessageModeEnabled
                )
            }
        case .stop, .subagentStop:
            let assistantFinalMessage = event.assistantFinalMessage
            Task { @MainActor [weak self, rawWorkspaceId, assistantFinalMessage, iMessageModeEnabled] in
                guard let self,
                      let workspaceId = self.v2UUIDAny(rawWorkspaceId) else { return }
                guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: workspaceId) else { return }
                _ = tabManager.handleAssistantFinalMessage(
                    workspaceId: workspaceId,
                    message: assistantFinalMessage,
                    iMessageModeEnabled: iMessageModeEnabled
                )
            }
        default:
            break
        }
    }

    nonisolated func v2FeedPermissionReply(params: [String: Any]) -> V2CallResult {
        guard let requestId = params["request_id"] as? String else {
            return .err(
                code: "invalid_params",
                message: "feed.permission.reply requires request_id",
                data: nil
            )
        }
        guard let modeRaw = params["mode"] as? String,
              let mode = WorkstreamPermissionMode(rawValue: modeRaw)
        else {
            return .err(
                code: "invalid_params",
                message: "feed.permission.reply requires mode ∈ once|always|all|bypass|deny",
                data: nil
            )
        }
        FeedCoordinator.shared.deliverReply(
            requestId: requestId,
            decision: .permission(mode)
        )
        return .ok(["delivered": true])
    }

    nonisolated func v2FeedQuestionReply(params: [String: Any]) -> V2CallResult {
        guard let requestId = params["request_id"] as? String else {
            return .err(
                code: "invalid_params",
                message: "feed.question.reply requires request_id",
                data: nil
            )
        }
        guard let selections = params["selections"] as? [String] else {
            return .err(
                code: "invalid_params",
                message: "feed.question.reply requires selections: [string]",
                data: nil
            )
        }
        FeedCoordinator.shared.deliverReply(
            requestId: requestId,
            decision: .question(selections: selections)
        )
        return .ok(["delivered": true])
    }

    nonisolated func v2FeedExitPlanReply(params: [String: Any]) -> V2CallResult {
        guard let requestId = params["request_id"] as? String else {
            return .err(
                code: "invalid_params",
                message: "feed.exit_plan.reply requires request_id",
                data: nil
            )
        }
        guard let modeRaw = params["mode"] as? String,
              let mode = WorkstreamExitPlanMode(rawValue: modeRaw)
        else {
            return .err(
                code: "invalid_params",
                message: "feed.exit_plan.reply requires mode ∈ ultraplan|bypassPermissions|autoAccept|manual|deny",
                data: nil
            )
        }
        let feedback = params["feedback"] as? String
        FeedCoordinator.shared.deliverReply(
            requestId: requestId,
            decision: .exitPlan(mode, feedback: feedback)
        )
        return .ok(["delivered": true])
    }

    func v2FeedJump(params: [String: Any]) -> V2CallResult {
        guard let workstreamId = params["workstream_id"] as? String else {
            return .err(
                code: "invalid_params",
                message: "feed.jump requires workstream_id",
                data: nil
            )
        }
        // MVP: resolve to a cmux surface via `SessionIndexStore` lands in
        // the UI PR; for now we return whether the id is known so callers
        // can show a toast.
        let matched = FeedCoordinator.shared.resolvePossibleSurface(for: workstreamId)
        return .ok([
            "workstream_id": workstreamId,
            "matched": matched
        ])
    }

    func v2FeedList(params: [String: Any]) -> V2CallResult {
        let pendingOnly = (params["pending_only"] as? Bool) ?? false
        let items = FeedCoordinator.shared.snapshot(pendingOnly: pendingOnly)
        return .ok([
            "items": items.map { FeedSocketEncoding.itemDict($0) }
        ])
    }

    // MARK: - V2 App Focus Methods

    func v2AppFocusOverride(params: [String: Any]) -> V2CallResult {
        // Accept either:
        // - state: "active" | "inactive" | "clear"
        // - focused: true/false/null
        if let state = v2String(params, "state")?.lowercased() {
            switch state {
            case "active":
                AppFocusState.overrideIsFocused = true
            case "inactive":
                AppFocusState.overrideIsFocused = false
            case "clear", "none":
                AppFocusState.overrideIsFocused = nil
            default:
                return .err(code: "invalid_params", message: "Invalid state (active|inactive|clear)", data: ["state": state])
            }
        } else if params.keys.contains("focused") {
            if let focused = v2Bool(params, "focused") {
                AppFocusState.overrideIsFocused = focused
            } else {
                AppFocusState.overrideIsFocused = nil
            }
        } else {
            return .err(code: "invalid_params", message: "Missing state or focused", data: nil)
        }

        let overrideVal: Any = v2OrNull(AppFocusState.overrideIsFocused.map { $0 as Any })
        return .ok(["override": overrideVal])
    }

    func v2AppSimulateActive() -> V2CallResult {
        v2MainSync {
            AppDelegate.shared?.applicationDidBecomeActive(
                Notification(name: NSApplication.didBecomeActiveNotification)
            )
        }
        return .ok([:])
    }

    // MARK: - V2 Browser Methods

}
