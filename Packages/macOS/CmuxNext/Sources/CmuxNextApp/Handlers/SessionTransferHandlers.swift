import CmuxNextActions

/// The one action path for the palette, keyboard, CLI and control socket.
enum SessionTransferHandlers {
    static func bind(into registry: ActionRegistry, context ctx: AppActionContext) {
        registry.bind("session.moveHere") { invocation in
            let source = invocation["source"]?.stringValue
            let ids = Set((invocation["ids"]?.stringValue ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
            ctx.services.sessionTransfer.start(source: source, ids: ids)
        }
    }
}
