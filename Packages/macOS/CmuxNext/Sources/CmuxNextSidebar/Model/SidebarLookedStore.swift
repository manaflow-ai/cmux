public import Foundation
public import Observation

/// When the person last looked at each workspace (`sidebar.sinceLooked`): stamped when the
/// selection leaves it, kept on this Mac. The hover card counts what its agents did since then.
@Observable @MainActor
public final class SidebarLookedStore {
    public static let shared = SidebarLookedStore(defaults: .standard)

    public private(set) var stamps: [WorkspaceID: Date] {
        didSet { if stamps != oldValue { save() } }
    }

    @ObservationIgnored private let defaults: UserDefaults?
    private static let key = "cmux.next.sidebar.lastLooked"
    /// The most workspaces remembered; the oldest stamps go first.
    static let limit = 256

    /// `defaults` nil keeps the stamps in memory only (tests).
    public init(defaults: UserDefaults?) {
        self.defaults = defaults
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

    private func save() {
        guard let defaults, let data = try? JSONEncoder().encode(stamps) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
