public import CmuxNextActions

/// Safe mode's palette actions (docs/cmux-next/extensions/safe-mode.md): every extension off, the
/// native views on. Entering is allowed from any origin; leaving only as the person on the verified
/// connection (the supervisor refuses an agent's, with why).
extension AppsClient {
    /// Binds `safeMode.enter` and `safeMode.leave` to `safe_mode.set {on}` with the invocation's origin.
    public func installSafeModeActions(in registry: ActionRegistry) {
        for (id, on) in [("safeMode.enter", true), ("safeMode.leave", false)] as [(ActionID, Bool)] {
            registry.bindEffect(id, effect: { [weak self] invocation in
                self?.safeModeEffect(on, invocation) ?? .refused(AppsUnavailableReason.notConnected.text)
            })
        }
    }

    func safeModeEffect(_ on: Bool, _ invocation: ActionInvocation) -> ActionEffect {
        if let reason = unavailableReason { return .refused(reason.text) }
        let origin = AppOrigin(rawValue: invocation.origin.rawValue) ?? .script
        // action-wait-allow: the flag is the daemon's (apps/safe_mode.rs), which may refuse a leave; no local stand-in
        return .waiting(.daemonEcho) { [weak self] in
            guard let self else { return nil }
            do throws(AppsClientError) {
                _ = try await setSafeMode(on, origin: origin)
                return nil
            } catch {
                return ActionWorkFailure(error.description)
            }
        }
    }
}
