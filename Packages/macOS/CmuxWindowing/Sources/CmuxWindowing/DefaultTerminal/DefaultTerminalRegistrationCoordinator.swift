public import Foundation

/// Orchestrates the user-driven "Make cmux the default terminal" flow: it reads
/// the current registration status, runs the LaunchServices registration through
/// a ``DefaultTerminalRegistrar``, and coalesces concurrent attempts so a second
/// tap while one is in flight never spawns a duplicate registration.
///
/// Lifted from AppDelegate's `DefaultTerminalUserAction`, which was a caseless
/// `@MainActor enum` namespace of `static` members carrying a `static var
/// inFlightRegistration`. CONVENTIONS bans both shapes (a static-only namespace
/// and runtime state on a namespace type), so the behavior moved onto this real
/// instance type whose collaborators are constructor-injected.
///
/// The two app-coupled pieces stay app-side and are inverted through closures:
/// the `DefaultTerminalRegistrar` itself (so the live `Bundle.main` URL and the
/// `.defaultTerminalRegistrationDidChange` post are supplied by the composition
/// root via `makeRegistrar`), and failure presentation (so the NSAlert and its
/// `String(localized:)` copy resolve in the app bundle via
/// `onRegistrationFailure`; resolving them here would bind to the package bundle
/// and drop every non-English translation).
///
/// Isolation: `@MainActor`, because every entrypoint is a main-thread UI flow
/// (menu item, command palette, Settings row) and the in-flight dedup state is
/// read and written only from those flows; co-locating the state with its
/// callers keeps the dedup a plain property check with no bridging. The dedup
/// matches the legacy contract exactly: a waiter that joins an in-flight
/// operation returns `false` (it did not itself perform the registration), and a
/// failure of the in-flight operation is swallowed by the waiter rather than
/// rethrown.
@MainActor
@Observable
public final class DefaultTerminalRegistrationCoordinator {
    private struct RegistrationOperation {
        let id: UUID
        let task: Task<Void, any Error>
    }

    private var inFlightRegistration: RegistrationOperation?
    private let makeRegistrar: @MainActor () -> DefaultTerminalRegistrar
    private let onRegistrationFailure: @MainActor (any Error) -> Void
    private let debugLog: @Sendable (String) -> Void

    /// Creates a coordinator with explicit collaborators.
    /// - Parameters:
    ///   - makeRegistrar: Builds a fresh ``DefaultTerminalRegistrar`` per call;
    ///     the composition root injects the live `Bundle.main.bundleURL`,
    ///     `NSWorkspace.shared`, and the `.defaultTerminalRegistrationDidChange`
    ///     post closure.
    ///   - onRegistrationFailure: Presents a registration failure to the user;
    ///     the app passes a closure that shows the NSAlert with app-bundle
    ///     localized copy derived from the typed
    ///     ``DefaultTerminalRegistrationError``.
    ///   - debugLog: DEBUG sink for the `defaultTerminal.setAsDefault …` trace
    ///     lines (the app passes `cmuxDebugLog` in DEBUG, a no-op otherwise).
    public init(
        makeRegistrar: @escaping @MainActor () -> DefaultTerminalRegistrar,
        onRegistrationFailure: @escaping @MainActor (any Error) -> Void,
        debugLog: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.makeRegistrar = makeRegistrar
        self.onRegistrationFailure = onRegistrationFailure
        self.debugLog = debugLog
    }

    /// The current default-terminal registration status read through a fresh
    /// registrar. Reads do not fire the change notifier.
    /// - Returns: The current ``DefaultTerminalRegistrationStatus``.
    public func currentStatus() -> DefaultTerminalRegistrationStatus {
        makeRegistrar().currentStatus()
    }

    /// Registers this bundle as the default terminal, coalescing with any
    /// in-flight attempt.
    /// - Returns: `true` when this call performed the registration, `false` when
    ///   it joined (and waited on) an attempt already in flight.
    /// - Throws: ``DefaultTerminalRegistrationError`` when this call's own
    ///   registration fails. A failure of a *joined* in-flight attempt is not
    ///   rethrown (the waiter returns `false`).
    @discardableResult
    public func registerAsDefault() async throws -> Bool {
        if let operation = inFlightRegistration {
            do {
                try await operation.task.value
            } catch {
                return false
            }
            return false
        }

        let makeRegistrar = self.makeRegistrar
        let operation = RegistrationOperation(
            id: UUID(),
            task: Task {
                try await makeRegistrar().setAsDefault()
            }
        )
        inFlightRegistration = operation

        do {
            try await operation.task.value
            if inFlightRegistration?.id == operation.id {
                inFlightRegistration = nil
            }
            return true
        } catch {
            if inFlightRegistration?.id == operation.id {
                inFlightRegistration = nil
            }
            throw error
        }
    }

    /// Fire-and-forget entrypoint for the menu/palette/Settings actions: kicks
    /// off `registerAsDefault()` and routes any failure to the injected
    /// presenter.
    /// - Parameter debugSource: A short label naming the entrypoint, recorded in
    ///   the DEBUG trace.
    public func setAsDefault(debugSource: String) {
        debugLog("defaultTerminal.setAsDefault source=\(debugSource)")
        Task {
            do {
                try await registerAsDefault()
            } catch {
                debugLog("defaultTerminal.setAsDefault.failed source=\(debugSource) error=\(error)")
                onRegistrationFailure(error)
            }
        }
    }
}
