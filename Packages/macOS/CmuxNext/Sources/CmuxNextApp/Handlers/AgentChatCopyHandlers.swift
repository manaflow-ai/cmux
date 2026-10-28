import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextDaemon
import Foundation

/// Explicit clipboard exports for the focused agent chat. The session id and pane key are captured
/// before any page or socket await; a late reply never writes another chat's text to the clipboard.
enum AgentChatCopyHandlers {
    private static let nameAction: ActionID = "agentChat.copyName"
    private static let harnessSessionAction: ActionID = "agentChat.copyHarnessSessionID"
    private static let conversationAction: ActionID = "agentChat.copyConversation"
    private static let detailsAction: ActionID = "agentChat.copySessionDetails"
    private static let cwdAction: ActionID = "agentChat.copyWorkingDirectory"
    private static let hostAction: ActionID = "agentChat.copyHost"

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let fields: [(ActionID, Field)] = [(nameAction, .name), (harnessSessionAction, .harnessSessionID), (conversationAction, .conversation),
                                           (detailsAction, .details), (cwdAction, .workingDirectory), (hostAction, .host)]
        for (id, field) in fields {
            registry.bind(id, invoke: { invocation in
                guard let target = focusedChat(context, invocation) else { return }
                // The page or socket read is awaited off the action's turn; the copy is one task of the run's
                // completion, and only while the chat is still the focused one.
                registry.trackWork(owner: "AgentChatCopyHandlers.copy", on: context.services.mainWork) {
                    await outcome(of: field, target, context: context)
                } then: { result in
                    guard case .success(let outcome) = result else { return nil }
                    let (missing, failure) = strings(of: field)
                    return finish(isCurrent(target, context: context) ? outcome : .stale, missing: missing, failure: failure,
                                  copy: { copy($0, context: context) })
                }
            })
        }
    }

    /// What one Copy row exports from the focused chat.
    private nonisolated enum Field: Sendable {
        case name, harnessSessionID, conversation, details, workingDirectory, host
    }

    /// `field` read from `target`'s session (its socket or its page), or stale once the chat is no longer the focused one.
    private static func outcome(of field: Field, _ target: Target, context: AppActionContext) async -> AgentChatCopyOutcome {
        let current: @MainActor () -> Bool = { isCurrent(target, context: context) }
        let info = infoReader(target)
        switch field {
        case .name:
            return await AgentChatCopyOperations.name(info: info, isCurrent: current)
        case .harnessSessionID:
            return await AgentChatCopyOperations.harnessSessionID(info: info, fallback: target.fallbackHarnessSessionID, isCurrent: current)
        case .conversation:
            return await AgentChatCopyOperations.conversation({
                let result = try await target.view.callPageScript("return await window.cmuxAcpmuxBridge?.conversationMarkdown?.() ?? null;")
                return result as? String
            }, isCurrent: current)
        case .details:
            return await AgentChatCopyOperations.details(info: info, identifier: target.sessionID,
                                                         fallbackHarnessSessionID: target.fallbackHarnessSessionID,
                                                         fallbackCWD: target.fallbackCWD, host: target.host, isCurrent: current)
        case .workingDirectory:
            return await AgentChatCopyOperations.workingDirectory(info: info, fallback: target.fallbackCWD, isCurrent: current)
        case .host:
            return await AgentChatCopyOperations.host(target.host, isCurrent: current)
        }
    }

    /// The refusals of `field`: nothing to copy, and a read that failed (nil: the same as nothing to copy).
    private static func strings(of field: Field) -> (missing: String, failure: String?) {
        switch field {
        case .name: (AgentChatCopyStrings.noName, nil)
        case .harnessSessionID: (AgentChatCopyStrings.noHarnessSession, nil)
        case .conversation: (AgentChatCopyStrings.noConversation, AgentChatCopyStrings.copyFailed)
        case .details: (AgentChatCopyStrings.noDetails, nil)
        case .workingDirectory: (AgentChatCopyStrings.noCWD, nil)
        case .host: (AgentChatCopyStrings.noHost, nil)
        }
    }

    private nonisolated struct Target: Sendable {
        let view: AgentPaneView
        let tabKey: String
        let paneKey: String
        let sessionID: String
        let fallbackCWD: String?
        let host: String?
        let fallbackHarnessSessionID: String?
        let socket: String?
    }

    @MainActor
    private static func finish(_ outcome: AgentChatCopyOutcome, missing: String, failure: String? = nil,
                               copy: @escaping @MainActor (String) -> Void) -> ActionWorkFailure? {
        switch outcome {
        case .copied(let text):
            copy(text)
            return nil
        case .stale:
            return nil
        case .missing:
            return refusal(missing)
        case .failed:
            return refusal(failure ?? missing)
        }
    }

    @MainActor
    private static func focusedChat(_ context: AppActionContext, _ invocation: ActionInvocation) -> Target? {
        guard let pane = context.scope(invocation).pane, let key = pane.currentTabKey, // view-observation-allow: one MachineTabIndex lookup, once per run
              let view = context.services.agentTabs.existingView(key), let tab = context.services.locateTab(key)?.0,
              let session = view.model.sessionId, !session.isEmpty, tab.agentSession != nil else {
            context.refuse(AgentChatCopyStrings.notAChat)
            return nil
        }
        return Target(view: view, tabKey: key, paneKey: pane.paneKey, sessionID: session,
                      fallbackCWD: view.model.transport.sessions.folder(of: session) ?? tab.cwd,
                      host: tab.agentSession?.hostName ?? tab.agentSession?.host,
                      fallbackHarnessSessionID: tab.agent?.harnessSessionID,
                      socket: view.model.sessionCopySocketPath)
    }

    private static func infoReader(_ target: Target) -> () async -> [String: Any]? {
        guard let socket = target.socket else { return { nil } }
        let session = target.sessionID
        return { await AgentPaneModel.sessionCopyInfo(socketPath: socket, sessionID: session) }
    }

    @MainActor
    private static func isCurrent(_ target: Target, context: AppActionContext) -> Bool {
        // view-observation-allow: one MachineTabIndex lookup per check, before and after the read
        guard let located = context.services.locateTab(target.tabKey),
              context.services.paneController(for: located.1)?.currentTabKey == target.tabKey,
              context.services.windows.active?.focusedPane?.paneKey == target.paneKey,
              context.services.agentTabs.existingView(target.tabKey) === target.view,
              target.view.model.sessionId == target.sessionID,
              target.view.model.sessionCopySocketPath == target.socket else { return false }
        return true
    }

    @MainActor private static func copy(_ text: String, context: AppActionContext) { context.copy(text) }
    private static func refusal(_ message: String) -> ActionWorkFailure { ActionWorkFailure(refusal: .unavailable, reason: message) }
}


private enum AgentChatCopyStrings {
    static var notAChat: String { String(localized: "agentChat.copy.notAChat", defaultValue: "Focus a started agent chat first.", table: "Handlers", bundle: .module) }
    static var noName: String { String(localized: "agentChat.copyName.noName", defaultValue: "The focused chat has no agent name yet.", table: "Handlers", bundle: .module) }
    static var noHarnessSession: String { String(localized: "agentChat.copyHarnessSessionID.noSession", defaultValue: "The focused chat has no harness session ID yet.", table: "Handlers", bundle: .module) }
    static var noConversation: String { String(localized: "agentChat.copyConversation.noConversation", defaultValue: "The focused chat has no conversation to copy yet.", table: "Handlers", bundle: .module) }
    static var noDetails: String { String(localized: "agentChat.copySessionDetails.noDetails", defaultValue: "The focused chat has no session details to copy yet.", table: "Handlers", bundle: .module) }
    static var noCWD: String { String(localized: "agentChat.copyWorkingDirectory.noCWD", defaultValue: "The focused chat has no working directory yet.", table: "Handlers", bundle: .module) }
    static var noHost: String { String(localized: "agentChat.copyHost.noHost", defaultValue: "The focused chat has no host name yet.", table: "Handlers", bundle: .module) }
    static var copyFailed: String { String(localized: "agentChat.copyConversation.failed", defaultValue: "The focused chat could not provide its conversation.", table: "Handlers", bundle: .module) }
}
