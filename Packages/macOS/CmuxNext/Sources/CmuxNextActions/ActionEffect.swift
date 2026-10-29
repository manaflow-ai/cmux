/// What an action's synchronous part did: the value a handler bound with
/// ``ActionRegistry/bindEffect(_:isEnabled:effect:)`` returns, on the input's own turn.
///
/// The handler applies the visible change before it returns and hands any remote work to the
/// registry as a value; it never awaits. The registry sends, reconciles and rolls back
/// (``ActionConfirmation``). An action that shows nothing until a reply must say so in its type
/// (``waiting(_:_:)``), and the registry counts those runs (plans/cmux-next/zero-latency.md, "Native
/// actions: the budget contract").
///
/// ```swift
/// registry.bindEffect("renamePane", effect: { invocation in
///     guard let pane = context.daemonPane(invocation), let name = invocation["name"]?.stringValue else { return .done }
///     return context.daemon.intent("rename-pane", .renamePane(pane: pane.handle, name: name)) { try await $0.renamePane(pane.handle, to: name) }
/// })
/// ```
public struct ActionEffect {
    enum Kind {
        case done
        case applied(ActionConfirmation)
        case waiting(ActionWait, @MainActor () async -> ActionWorkFailure?)
        case refused(String, quiet: Bool)
    }

    let kind: Kind

    /// The whole change happened on this turn (a local selection, a focus move, a view toggle).
    public static let done = ActionEffect(kind: .done)

    /// The local change is shown on this turn; the registry sends `confirmation`'s command and rolls
    /// the change back with visible feedback when it fails.
    ///
    /// - Parameter confirmation: The command and its rollback.
    public static func applied(_ confirmation: ActionConfirmation) -> ActionEffect {
        ActionEffect(kind: .applied(confirmation))
    }

    /// Nothing shows until `work` answers. Counted per action (``ActionRegistry/waitingRuns``); the
    /// pre-push guardrail `action-wait` refuses a new use without a reviewed reason.
    ///
    /// - Parameters:
    ///   - reason: Why no local change can show first.
    ///   - work: The remote work; nil on success, else the failure.
    public static func waiting(_ reason: ActionWait, _ work: @escaping @MainActor () async -> ActionWorkFailure?) -> ActionEffect {
        ActionEffect(kind: .waiting(reason, work))
    }

    /// The action cannot act on this invocation; `reason` goes to the caller (``ActionRegistry/refuse(_:quiet:)``).
    ///
    /// - Parameters:
    ///   - reason: Why, shown to the person (localized).
    ///   - quiet: A navigation with no target: no notice for a keyboard or menu run.
    public static func refused(_ reason: String, quiet: Bool = false) -> ActionEffect {
        ActionEffect(kind: .refused(reason, quiet: quiet))
    }
}
