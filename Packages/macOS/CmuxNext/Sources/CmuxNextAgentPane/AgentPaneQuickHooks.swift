import Foundation

/// The app side of Start Agent's panel (cx-hkat), its page's `quick.*` requests:
/// hide the panel, open the chat in the main window, place a started chat, and
/// the floating chat's keep-on-top and compact bar (cx-b9qi).
public struct AgentPaneQuickHooks {
    /// `quick.dismiss`: Esc hid the panel, keeping its draft.
    public var dismiss: () -> Void
    /// `quick.openInWindow`: open the chat in the main window. Gets the chat's
    /// session, nil before the first prompt.
    public var openInWindow: (String?) -> Void
    /// `quick.startInBackground`: Return started the chat. The reply waits
    /// until the host placed it or failed.
    public var startInBackground: @MainActor (AgentPaneQuickStart) async -> Void
    /// `quick.setOnTop {onTop}`: the floating chat floats over other windows or not.
    public var setOnTop: (Bool) -> Void
    /// `quick.setCollapsed {collapsed}`: the floating chat folds to its compact bar or opens again.
    public var setCollapsed: (Bool) -> Void
    /// `quick.floatingState`: what the floating chat draws now, for a page that loads after the
    /// last push (a tab moved to the panel, a reload).
    public var floatingState: () -> AgentPaneFloatingState
    /// `quick.context`: what the user is looking at in cmux (Include focused tab), nil for nothing.
    public var context: @MainActor () async -> AgentPaneQuickContext?

    public init(dismiss: @escaping () -> Void,
                openInWindow: @escaping (String?) -> Void,
                startInBackground: @escaping @MainActor (AgentPaneQuickStart) async -> Void,
                setOnTop: @escaping (Bool) -> Void = { _ in },
                setCollapsed: @escaping (Bool) -> Void = { _ in },
                floatingState: @escaping () -> AgentPaneFloatingState = { AgentPaneFloatingState() },
                context: (@MainActor () async -> AgentPaneQuickContext?)? = nil) {
        self.dismiss = dismiss
        self.openInWindow = openInWindow
        self.startInBackground = startInBackground
        self.setOnTop = setOnTop
        self.setCollapsed = setCollapsed
        self.floatingState = floatingState
        self.context = context ?? { nil }
    }
}

extension AgentPaneQuickHooks {
    /// The panel requests that move the chat: its session becomes `model`'s first.
    @MainActor func respond(to request: AgentPaneRequest, in model: AgentPaneModel) async -> [String: Any] {
        switch request {
        case .quickOpenInWindow(let session):
            if let session { model.adoptSession(session) }
            openInWindow(model.sessionId)
        case .quickStartInBackground(let start):
            model.adoptSession(start.sessionId)
            await startInBackground(start)
        default: return await respond(to: request)
        }
        return AgentPaneReply.success()
    }

    /// The panel requests that leave the chat's session alone.
    func respond(to request: AgentPaneRequest) async -> [String: Any] {
        switch request {
        case .quickDismiss: dismiss()
        case .quickSetOnTop(let onTop): setOnTop(onTop)
        case .quickSetCollapsed(let collapsed): setCollapsed(collapsed)
        case .quickFloatingState: return AgentPaneReply.success(floatingState().reply)
        case .quickContext: return AgentPaneReply.success(await context()?.reply ?? NSNull())
        default: return AgentPaneModel.unsupported(String(describing: request))
        }
        return AgentPaneReply.success()
    }
}
