// Performing an action: the one path every entrypoint (keyboard, menu, palette, context menu,
// CLI, socket) runs through. Availability, the key window's route, argument collection and the
// destructive gate, then the handler, each timed (`ActionRegistry+Signposts`).
extension ActionRegistry {
    /// Performs the action if it is bound, available, and enabled. Returns
    /// whether it ran.
    @discardableResult
    public func perform(_ id: ActionID) -> Bool {
        perform(id, invocation: ActionInvocation())
    }

    /// Performs an action that takes one argument. The text is parsed with
    /// the descriptor's first argument; handlers without a schema get it
    /// through `argumentHandler`.
    @discardableResult
    public func perform(_ id: ActionID, argument: String) -> Bool {
        let schema = descriptor(for: id)?.arguments.first
        let name = schema?.name ?? "value"
        let value = schema?.parse(argument) ?? .string(argument)
        return perform(id, invocation: ActionInvocation(arguments: [name: value]))
    }

    /// Performs with a target and typed arguments (palette, CLI, context menus). Fails when a required argument is missing.
    @discardableResult
    public func perform(_ id: ActionID, invocation: ActionInvocation) -> Bool {
        settlingPreview(for: id) { settle in performNow(id, invocation: invocation, settle: settle) }
    }

    /// `settle` puts a preview of another action back; every path that does work calls it first,
    /// inside its timing (`ActionRegistry+Preview`).
    private func performNow(_ id: ActionID, invocation: ActionInvocation, settle: () -> Void) -> Bool {
        if disabledFeature(for: id) != nil { return false }
        if let route = keyWindowRoute?(canonicalID(for: id), invocation) {
            guard case .run = route else { return route.perform { refuse($0) } }
            // A route run of an id nothing bound (rare) interns it here, once.
            let index = action(for: id)?.timingIndex ?? runTiming.intern(canonicalID(for: id))
            return signposted(id, index: index, invocation) {
                settle()
                return route.perform { refuse($0) }
            }
        }
        guard let action = action(for: id), isAvailable(id, for: invocation) else { return false }
        guard action.isEnabled() else {
            // A person's run of an action a recovery covers (Sign In for a signed-out Cloud action)
            // takes that way past the reason, then runs; every other caller is refused as before.
            guard let recovery = personRecovery(for: id, invocation) else { return false }
            signposted(id, index: action.timingIndex, invocation) {
                settle()
                recovery.run(canonicalID(for: id), invocation)
            }
            return true
        }
        if ActionTargetReasons.refuses(action, invocation, in: self) { return false }
        let missing = descriptor(for: id).map { descriptor in
            descriptor.arguments.contains { $0.isRequired && invocation.arguments[$0.name] == nil && !Self.target(of: invocation, supplies: $0, for: descriptor) }
        } ?? false
        if missing, let argumentCollector {
            // A menu item or shortcut for an argument-taking action: let the
            // palette ask for the rest, then run with the full invocation.
            // The palette opening is a gate, not a run of the action.
            gated(id, invocation) { stamped in
                settle()
                argumentCollector(id, stamped)
            }
            return true
        }
        if needsConfirmation(id, invocation) { return gateDestructive(id, invocation, settle: settle) }
        signposted(id, index: action.timingIndex, invocation) {
            settle()
            runScoped(action, id, invocation)
        }
        return true
    }
}
