import CmuxNextActions

/// The registry context bits a pane's content implies.
enum ContentContext {
    static func merged(_ base: ActionContext, content: TabContent?) -> ActionContext {
        var context = base
        context.subtract([.terminalFocused, .browserFocused])
        switch content {
        case .terminal: context.insert(.terminalFocused)
        case .browser: context.insert(.browserFocused)
        case nil: break
        }
        return context
    }
}
