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
        registry.bind(nameAction, invoke: { invocation in
            guard let target = focusedChat(context, invocation) else { return }
            let info = infoReader(target)
            let work: ActionWork = Task { await finish(AgentChatCopyOperations.name(info: info, isCurrent: { isCurrent(target, context: context) }), missing: AgentChatCopyStrings.noName, copy: { copy($0, context: context) }) }
            registry.track(work)
        })
        registry.bind(harnessSessionAction, invoke: { invocation in
            guard let target = focusedChat(context, invocation) else { return }
            let info = infoReader(target)
            let work: ActionWork = Task { await finish(AgentChatCopyOperations.harnessSessionID(info: info, fallback: target.fallbackHarnessSessionID, isCurrent: { isCurrent(target, context: context) }), missing: AgentChatCopyStrings.noHarnessSession, copy: { copy($0, context: context) }) }
            registry.track(work)
        })
        registry.bind(conversationAction, invoke: { invocation in
            guard let target = focusedChat(context, invocation) else { return }
            let work: ActionWork = Task {
                await finish(AgentChatCopyOperations.conversation({
                    let result = try await target.view.callPageScript("return await window.cmuxAcpmuxBridge?.conversationMarkdown?.() ?? null;")
                    return result as? String
                }, isCurrent: { isCurrent(target, context: context) }), missing: AgentChatCopyStrings.noConversation, failure: AgentChatCopyStrings.copyFailed, copy: { copy($0, context: context) })
            }
            registry.track(work)
        })
        registry.bind(detailsAction, invoke: { invocation in
            guard let target = focusedChat(context, invocation) else { return }
            let info = infoReader(target)
            let work: ActionWork = Task {
                await finish(AgentChatCopyOperations.details(info: info, identifier: target.sessionID,
                                                     fallbackHarnessSessionID: target.fallbackHarnessSessionID,
                                                     fallbackCWD: target.fallbackCWD, host: target.host,
                                                     isCurrent: { isCurrent(target, context: context) }), missing: AgentChatCopyStrings.noDetails, copy: { copy($0, context: context) })
            }
            registry.track(work)
        })
        registry.bind(cwdAction, invoke: { invocation in
            guard let target = focusedChat(context, invocation) else { return }
            let info = infoReader(target)
            let work: ActionWork = Task { await finish(AgentChatCopyOperations.workingDirectory(info: info, fallback: target.fallbackCWD, isCurrent: { isCurrent(target, context: context) }), missing: AgentChatCopyStrings.noCWD, copy: { copy($0, context: context) }) }
            registry.track(work)
        })
        registry.bind(hostAction, invoke: { invocation in
            guard let target = focusedChat(context, invocation) else { return }
            let work: ActionWork = Task { await finish(AgentChatCopyOperations.host(target.host, isCurrent: { isCurrent(target, context: context) }), missing: AgentChatCopyStrings.noHost, copy: { copy($0, context: context) }) }
            registry.track(work)
        })
    }

    private struct Target {
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
        guard let pane = context.scope(invocation).pane, let key = pane.currentTabKey,
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
