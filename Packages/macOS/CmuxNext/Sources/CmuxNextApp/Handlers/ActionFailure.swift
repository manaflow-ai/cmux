import CmuxNextActions

/// A typed reason a workspace/window/settings handler could not act. Thrown
/// from handlers bound with `bind(_:run:)`, it reaches the control socket
/// as `unavailable: <message>` through `ActionRegistry.refuse`.
struct ActionFailure: Error, Hashable, CustomStringConvertible {
    let message: String
    /// An explicit target names nothing: the control socket answers `not_found`.
    var isNotFound = false
    /// A navigation or focus move with no target (R136): no notice for a
    /// keyboard or menu run; callers still get the message.
    var isQuiet = false

    /// The cmux-tui daemon does not serve `capability`.
    static func needsDaemonCapability(_ capability: String) -> ActionFailure {
        ActionFailure(message: RefusalStrings.needsDaemonCapability(capability))
    }

    /// cmux-next has no implementation of `feature` yet.
    static func needsAppCapability(_ feature: String) -> ActionFailure {
        ActionFailure(message: RefusalStrings.needsAppCapability(feature))
    }

    static func invalidTarget(_ message: String) -> ActionFailure {
        ActionFailure(message: message)
    }

    static func noTarget(_ message: String) -> ActionFailure {
        ActionFailure(message: message, isQuiet: true)
    }

    static func notFound(_ message: String) -> ActionFailure {
        ActionFailure(message: message, isNotFound: true)
    }

    var description: String { message }
}

extension ActionRegistry {
    /// Binds a throwing handler; a thrown error is reported with `refuse`.
    /// With `requires`, the action is unavailable (disabled in every surface)
    /// while the daemon lacks that capability.
    @discardableResult
    /// `daemon` is read when availability is asked (the active window's
    /// machine then), not when the action is bound.
    func bind(_ id: ActionID, requires capability: String? = nil, daemon: @autoclosure @escaping @MainActor () -> DaemonService? = nil,
              run: @escaping @MainActor (ActionInvocation) throws -> Void) -> Bool {
        let reason: @MainActor () -> String? = {
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
                self?.refuse(String(describing: error))
            }
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
