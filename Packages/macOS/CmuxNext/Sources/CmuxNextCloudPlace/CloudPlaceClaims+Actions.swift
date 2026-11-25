public import CmuxNextActions

/// A place move as an action run reads and writes it: the page's claims in, the move's arguments out (``CloudPlaceHost``).
extension CloudPlaceClaims {
    /// The cargo the page sent with its action (strings, as every page argument is); none when it sent none.
    public init(_ invocation: ActionInvocation) {
        self.init(queued: invocation["queued"].flatMap { $0.intValue ?? $0.stringValue.flatMap(Int.init) },
                  hasDraft: invocation["hasDraft"].flatMap { $0.boolValue ?? $0.stringValue.map { $0 == "true" } })
    }

    /// The Move to Cloud or Bring Back run's arguments: who started it, these claims, and the machine it lands on.
    public func arguments(trigger: CloudPlaceFlows.Trigger, machine: CloudPlaceMachine?) -> [String: ActionValue] {
        var arguments: [String: ActionValue] = ["trigger": .string(trigger.argument)]
        if let queued { arguments["queued"] = .int(queued) }
        if let hasDraft { arguments["hasDraft"] = .bool(hasDraft) }
        switch machine {
        case .reuse(let id): arguments["machine"] = .string(id)
        case .create: arguments["newMachine"] = .bool(true)
        case nil: break
        }
        return arguments
    }
}
