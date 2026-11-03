import CmuxNextActions

extension ActionRegistry {
    /// Binds a throwing handler; a thrown error is reported with `refuse`.
    /// With `requires`, the action is unavailable (disabled in every surface)
    /// while the daemon lacks that capability; with `unavailable`, while it
    /// returns a reason.
    @discardableResult
    /// `daemon` is read when availability is asked (the active window's
    /// machine then), not when the action is bound.
    func bind(_ id: ActionID, requires capability: String? = nil, daemon: @autoclosure @escaping @MainActor () -> DaemonService? = nil,
              unavailable: @escaping @MainActor () -> String? = { nil },
              run: @escaping @MainActor (ActionInvocation) throws -> Void) -> Bool {
        let reason: @MainActor () -> String? = {
            if let reason = unavailable() { return reason }
            guard let capability, let daemon = daemon(), !daemon.supports(capability) else { return nil }
            return daemon.missingCapabilityMessage(capability)
        }
        return bind(id, unavailable: reason, invoke: { [weak self] invocation in
            do {
                try run(invocation)
            } catch let failure as ActionFailure where failure.isNotFound {
                self?.refuseNotFound(failure.message)
            } catch let failure as ActionFailure where failure.isQuiet {
                self?.refuse(failure.message, quiet: true)
            } catch {
                self?.refuse(RefusalStrings.describe(error))
            }
        })
    }

    /// ``bind(_:requires:daemon:unavailable:run:)`` for a handler that returns its ``ActionEffect``
    /// (the registry sends, rolls back and reports; zero-latency.md, the budget contract). A thrown
    /// ``ActionFailure`` refuses as with `run:`. `requires` has no default (pass nil), so a call
    /// without it is the package's non-throwing ``ActionRegistry/bindEffect(_:unavailable:effect:)``.
    @discardableResult
    func bindEffect(_ id: ActionID, requires capability: String?, daemon: @autoclosure @escaping @MainActor () -> DaemonService? = nil,
              unavailable: @escaping @MainActor () -> String? = { nil },
              effect: @escaping @MainActor (ActionInvocation) throws -> ActionEffect) -> Bool {
        let reason: @MainActor () -> String? = {
            if let reason = unavailable() { return reason }
            guard let capability, let daemon = daemon(), !daemon.supports(capability) else { return nil }
            return daemon.missingCapabilityMessage(capability)
        }
        return bindEffect(id, unavailable: reason, effect: { [weak self] invocation in
            do {
                return try effect(invocation)
            } catch let failure as ActionFailure where failure.isNotFound {
                self?.refuseNotFound(failure.message)
            } catch let failure as ActionFailure where failure.isQuiet {
                self?.refuse(failure.message, quiet: true)
            } catch {
                self?.refuse(RefusalStrings.describe(error))
            }
            return .done
        })
    }

    /// Binds every ID as unavailable in this build with `failure`'s reason.
    func bindUnavailable(_ ids: [ActionID], _ failure: ActionFailure) {
        for id in ids {
            let bound = bindUnavailable(id, reason: failure.message)
            assert(bound, "\(id) is not in the action catalog")
        }
    }
}
