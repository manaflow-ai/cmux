public import Foundation
public import Observation
import CmuxNextWakeups

/// When the person last looked at each workspace (`sidebar.sinceLooked`): stamped when the
/// selection leaves it, kept on this Mac. The hover card counts what its agents did since then.
@Observable @MainActor
public final class SidebarLookedStore {
    public static let shared = SidebarLookedStore(defaults: .standard)

    public private(set) var stamps: [WorkspaceID: Date] {
        didSet { if stamps != oldValue { scheduleSave() } }
    }

    @ObservationIgnored private let defaults: UserDefaults?
    /// One write after the selection settles: a walk through the workspaces (Cmd-] held) stamps on
    /// every step, and each write JSON-encodes every stamp on the main thread.
    @ObservationIgnored private let saveTimer = DemandTimer(owner: "SidebarLookedStore.save")
    @ObservationIgnored private let saveDelay: Duration
    @ObservationIgnored private var dirty = false
    private static let key = "cmux.next.sidebar.lastLooked"
    /// The most workspaces remembered; the oldest stamps go first.
    static let limit = 256

    /// `defaults` nil keeps the stamps in memory only (tests). `saveDelay`: how long the stamps
    /// stay unchanged before they are written (a quit inside it loses only the newest stamps).
    public init(defaults: UserDefaults?, saveDelay: Duration = .seconds(2)) {
        self.defaults = defaults
        self.saveDelay = saveDelay
        stamps = defaults?.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([WorkspaceID: Date].self, from: $0) } ?? [:]
    }

    /// The person stopped looking at `id` at `now`.
    public func stamp(_ id: WorkspaceID, now: Date = Date()) {
        var next = stamps
        next[id] = now
        if next.count > Self.limit {
            for (old, _) in next.sorted(by: { $0.value < $1.value }).prefix(next.count - Self.limit) { next[old] = nil }
        }
        stamps = next
    }

    /// Writes pending stamps now.
    public func flush() {
        saveTimer.cancel()
        guard dirty else { return }
        dirty = false
        guard let defaults, let data = try? JSONEncoder().encode(stamps) else { return }
        defaults.set(data, forKey: Self.key)
    }

    private func scheduleSave() {
        guard defaults != nil else { return }
        dirty = true
        // A debounce deadline (the intended delay), cancelled by flush().
        saveTimer.schedule(after: saveDelay) { @MainActor [weak self] in self?.flush() }
    }
}
