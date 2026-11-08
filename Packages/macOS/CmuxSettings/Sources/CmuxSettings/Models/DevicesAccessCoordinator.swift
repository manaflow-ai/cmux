import Foundation

/// Serializes device preference actions shared by the sidebar and Settings.
@MainActor
public final class DevicesAccessCoordinator {
    /// The independently persisted device preferences.
    public enum Preference: Hashable, Sendable {
        /// Discover and connect to other Macs on the account.
        case discovery
        /// Advertise this Mac and accept incoming sessions.
        case incomingAccess
    }

    private let read: @MainActor (Preference) -> Bool
    private let write: @MainActor (Preference, Bool) async -> Void
    private let canChange: @MainActor (Preference) -> Bool
    private let confirmIncomingAccess: @MainActor () async -> Bool
    private var incomingConfirmation: UUID?
    private var writes: [Preference: (id: UUID, task: Task<Void, Never>)] = [:]

    /// Creates the shared action owner without duplicating persisted state.
    ///
    /// - Parameters:
    ///   - read: Reads the authoritative persisted value synchronously.
    ///   - write: Persists a changed value through the existing publication path.
    ///   - canChange: Resolves current feature availability and managed policy.
    ///   - confirmIncomingAccess: Presents confirmation and returns true only on consent.
    public init(
        read: @escaping @MainActor (Preference) -> Bool,
        write: @escaping @MainActor (Preference, Bool) async -> Void,
        canChange: @escaping @MainActor (Preference) -> Bool,
        confirmIncomingAccess: @escaping @MainActor () async -> Bool
    ) {
        self.read = read
        self.write = write
        self.canChange = canChange
        self.confirmIncomingAccess = confirmIncomingAccess
    }

    /// Requests a preference change, confirming only incoming access's off-to-on transition.
    ///
    /// Repeated enable requests share one pending decision. Cancellation writes nothing.
    /// Disabling invalidates a pending enable decision, and both preferences recheck policy
    /// before committing. Writes for each preference are ordered independently.
    /// - Parameters:
    ///   - enabled: The requested persisted value.
    ///   - preference: The independent preference to change.
    public func set(_ enabled: Bool, for preference: Preference) async {
        guard canChange(preference) else { return }
        if preference == .incomingAccess, enabled {
            guard incomingConfirmation == nil else { return }
            let request = UUID()
            incomingConfirmation = request
            defer {
                if incomingConfirmation == request { incomingConfirmation = nil }
            }
            await writes[preference]?.task.value
            guard incomingConfirmation == request, !read(preference), canChange(preference),
                  !Task.isCancelled else { return }
            guard await confirmIncomingAccess(), incomingConfirmation == request,
                  !Task.isCancelled else { return }
            await persist(true, for: preference, confirmation: request)
        } else {
            if preference == .incomingAccess { incomingConfirmation = nil }
            await persist(enabled, for: preference)
        }
    }

    private func persist(_ enabled: Bool, for preference: Preference, confirmation: UUID? = nil) async {
        let previous = writes[preference]?.task
        let id = UUID()
        let task = Task { @MainActor in
            await previous?.value
            if let confirmation, incomingConfirmation != confirmation { return }
            guard canChange(preference), read(preference) != enabled else { return }
            await write(preference, enabled)
        }
        writes[preference] = (id, task)
        await task.value
        if writes[preference]?.id == id { writes[preference] = nil }
    }
}
