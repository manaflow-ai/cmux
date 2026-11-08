public import CmuxNextActions

// `cmux cloud computer-control --machine <id> --action status|take_over|hand_back|request_human`
// (Chief computer take-over): who drives the Chief's computer on a Cloud machine. The lease and its
// rules live in ``ChiefComputerControlStore``, this app's one owner of it; the App's `CloudHandlers`
// binds the action to ``effect(_:knows:)``, and the profile's Computer tab changes the same store
// (`AppServices.chiefComputerControlSource(agent:machine:)`).
//
// Trust: no new policy. `status` answers any local caller (the Chief's `cloud_computer` tool reads it
// before each input). A change from another client (`remote`: a phone, another Mac) is refused,
// default deny. Only the person's own gesture takes over or gives back a computer the person took
// over (`computer.user_origin_required` otherwise), so a Chief cannot take control back from them;
// a local caller may ask the person (request_human), and an automated hand_back ends only that ask.
extension ChiefComputerControlStore {
    /// Who started the run `invocation` belongs to: a nested perform builds its invocation with the
    /// default `user` origin, so the enclosing run's scope (``ActionRunScope``) decides.
    private static func origin(of invocation: ActionInvocation) -> ActionOrigin {
        ActionRunScope.current?.origin ?? invocation.origin
    }

    /// Whether `invocation` is the person's own gesture in this app: a nested run inside a CLI or
    /// agent run stays automation (the run scope's origin).
    private static func byPerson(_ invocation: ActionInvocation) -> Bool {
        invocation.isPersonsOwnRun && origin(of: invocation) == .user
    }

    /// One `cloud.computerControl` run: the change on this turn, then `{machine, holder, since_ms, reason?}` as the result.
    public func effect(_ invocation: ActionInvocation, knows: (String) -> Bool) -> ActionEffect {
        do throws(Refusal) {
            let (machine, state) = try run(machine: invocation["machine"]?.stringValue, action: invocation["action"]?.stringValue,
                                           reason: invocation["reason"]?.stringValue, fromAnotherClient: Self.origin(of: invocation) == .remote,
                                           byPerson: Self.byPerson(invocation), knows: knows)
            var fields: [String: ActionResultValue] = ["machine": .string(machine), "holder": .string(state.holder.rawValue), "since_ms": .int(Int(state.sinceMs))]
            if let reason = state.reason { fields["reason"] = .string(reason) }
            return .applied(result: { [fields] in .success(fields) })
        } catch {
            return .refused(error.message)
        }
    }

    /// The refusal of an automated run (the Chief's tool, an agent, the CLI, MCP, a script, another
    /// client) that would act on Cloud machine `machine` while the person holds its computer
    /// (``checkNotHeld(machine:byPerson:)``): `cloud exec`, file writes and chats wait until they give
    /// it back, as the Worker refuses a Cloud Chief's exec on its own sandbox then. Nil for the
    /// person's own gesture in this app, as for take_over, and for a machine the Chief holds.
    public func heldRefusal(_ invocation: ActionInvocation, machine: String) -> String? {
        do throws(Refusal) {
            try checkNotHeld(machine: machine, byPerson: Self.byPerson(invocation))
            return nil
        } catch {
            return error.message
        }
    }
}
