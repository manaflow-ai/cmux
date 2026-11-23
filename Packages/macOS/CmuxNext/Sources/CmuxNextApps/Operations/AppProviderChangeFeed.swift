import CmuxNextCompat

/// Sends `apps-provider-changed` for one family when the data it serves changes, so app scripts
/// that subscribe to `<family>.changed` (the threads section's `agent_chat.changed`) read again
/// instead of polling. It observes the family's value (Observation, deduped by `==`) and sends only
/// while a registered provider carrier is attached; changes during a send coalesce into one more.
/// A carrier that is attached sends once at once, since the value may have changed while none was.
@MainActor
public final class AppProviderChangeFeed {
    /// Sends one change notice for a family on the attached carrier.
    public typealias Send = @Sendable (_ family: String) async throws -> Void

    /// The family this feed announces (for example `agent_chat`).
    public let family: String
    private let observe: @MainActor (AppProviderChangeFeed) -> Task<Void, Never>
    private var following: Task<Void, Never>?
    private var send: Send?
    private var sending: Task<Void, Never>?
    private var dirty = false

    /// Creates a feed over a value whose changes are the family's changes.
    /// - Parameters:
    ///   - family: The registered family to announce.
    ///   - value: Read on the main actor; a change of an observable value it reads, with a new result, is a change.
    public init<Value: Equatable & Sendable>(family: String, value: @escaping @MainActor @Sendable () -> Value) {
        self.family = family
        observe = { feed in
            let later = ObservationStream.current(value).later
            // task-owner: the feed's observation; detaching the carrier or deinit cancels it.
            return Task { [weak feed] in
                for await _ in later {
                    guard !Task.isCancelled else { return }
                    feed?.changed()
                }
            }
        }
    }

    nonisolated deinit { following?.cancel(); sending?.cancel() }

    /// Attaches the carrier that registered the family, or detaches it (nil) on reset or refusal.
    /// - Parameter send: Sends on the registered carrier; nil while none is registered.
    public func attach(_ send: Send?) {
        sending?.cancel(); sending = nil; dirty = false
        self.send = send
        guard send != nil else { following?.cancel(); following = nil; return }
        if following == nil { following = observe(self) }
        changed()
    }

    private func changed() {
        guard let send else { return }
        dirty = true
        guard sending == nil else { return }
        // task-owner: one coalesced notice loop; attach (a new or no carrier) cancels it.
        sending = Task { [weak self, family] in
            while let self, !Task.isCancelled, dirty {
                dirty = false
                do { try await send(family) } catch { break }
            }
            guard let self, !Task.isCancelled else { return }
            sending = nil
        }
    }
}
