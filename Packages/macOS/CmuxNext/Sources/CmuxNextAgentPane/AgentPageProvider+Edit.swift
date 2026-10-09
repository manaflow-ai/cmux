import CmuxNextPages

extension AgentPageProvider {
    /// `pane.edit {command}`: runs the composer menu's Cut, Copy, Paste or Paste as Plain Text through
    /// ``onEdit``. A paste puts the user's pasteboard into the page, so it needs their click or key.
    func edit(_ params: JSONValue, op: String, context: PageCallContext) throws -> JSONValue {
        guard let command = params["command"]?.stringValue.flatMap(AgentPaneEditCommand.init(rawValue:))
        else { throw PageError.invalidParams(op) }
        guard context.userGesture else { throw PageError(code: PageNativeOp.userOnlyCode, message: "") }
        onEdit?(command)
        return .null
    }
}
