import Foundation

/// Maps an agent-minted token to the surface whose output stream announced it.
///
/// Hooks need a surface to address, and `CMUX_SURFACE_ID` cannot supply one in
/// two common cases: shell integration deliberately clears it inside tmux
/// (identity inherited through a daemonized tmux server would be stale), and it
/// never survives SSH. Guessing from the focused surface is wrong -- a
/// background agent finishing would mis-deliver onto whatever pane the user
/// happens to be looking at.
///
/// Instead the agent announces itself: the launch wrapper mints a token, emits
/// it as an OSC 777 with a reserved title, and exports it into the agent's
/// environment. Ghostty attributes that sequence to the surface whose stream
/// carried it, so the announcement arrives already bound to the right surface
/// with no identity to inherit and nothing to go stale. Hooks then address the
/// socket by token.
///
/// This is deliberately one-way. A query/response handshake would have to write
/// a reply into the terminal, which any program reading the tty could observe
/// or be corrupted by; an announcement discloses nothing to the far side.
final class AgentSurfaceIdentityRegistry {
    /// Shared instance rather than injected: `record` is called from
    /// Ghostty's surface action callback, which is reached through a C ABI
    /// that cannot thread a dependency, and `binding(for:)` from nonisolated
    /// socket-worker bodies. Both are synchronous contexts.
    static let shared = AgentSurfaceIdentityRegistry()

    /// Reserved OSC 777 title. A notification carrying it is an identity
    /// announcement, not a user-visible message, and is never displayed.
    static let announcementTitle = "cmux.agent.identity"

    struct Binding {
        let tabId: UUID
        let surfaceId: UUID
        let announcedAt: Date
    }

    /// A token is minted per agent launch. Bindings are pruned on access
    /// rather than on a timer: the map is small, and a timer would keep the app
    /// awake for no benefit.
    private var bindings: [String: Binding] = [:]
    /// A lock rather than an actor, deliberately: both callers are
    /// synchronous and cannot await an actor hop — the Ghostty action
    /// callback on the render path, and the socket worker's nonisolated hook
    /// body. Every critical section is a dictionary read or write with no
    /// blocking or reentrancy inside.
    private let lock = NSLock()

    /// Bounds the map if an agent relaunches repeatedly.
    private let maximumBindings = 512

    /// A binding outlives its usefulness once the agent that announced it is
    /// gone, and nothing tells this registry when a surface closes. Expiring on
    /// access bounds the staleness window without needing that signal: an
    /// agent session far older than this is not one whose hooks are still
    /// firing, and resolving a recycled token onto a dead pane would be worse
    /// than failing closed.
    private let bindingLifetime: TimeInterval = 24 * 60 * 60

    private init() {}

    /// Records that `token` belongs to the surface that emitted the
    /// announcement. A repeated announcement for the same token refreshes it:
    /// an agent may re-announce after a resume, and the newest stream wins.
    func record(token: String, tabId: UUID, surfaceId: UUID, now: Date = Date()) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        bindings[trimmed] = Binding(tabId: tabId, surfaceId: surfaceId, announcedAt: now)
        guard bindings.count > maximumBindings else { return }
        let overflow = bindings.count - maximumBindings
        for key in bindings
            .sorted(by: { $0.value.announcedAt < $1.value.announcedAt })
            .prefix(overflow)
            .map(\.key) {
            bindings.removeValue(forKey: key)
        }
    }

    /// Returns the surface that announced `token`, or nil when the token was
    /// never announced. Callers must treat nil as "do not guess": delivering to
    /// a fallback surface is the mis-routing this registry exists to prevent.
    func binding(for token: String, now: Date = Date()) -> Binding? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let binding = bindings[trimmed] else { return nil }
        guard now.timeIntervalSince(binding.announcedAt) <= bindingLifetime else {
            bindings.removeValue(forKey: trimmed)
            return nil
        }
        return binding
    }
}
