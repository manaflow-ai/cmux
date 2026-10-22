public import Foundation
public import Observation
import CmuxNextWakeups

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

    /// The coalesced write: one deadline after the last stamp (`DemandTimer`, plans/cmux-next/idle-wakeups.md).
    @ObservationIgnored private let saveTimer = DemandTimer(owner: "sidebar.lookedStore.save")

    /// Coalesced: a workspace switch stamps the workspace it leaves, and the encode and the defaults write run once,
    /// half a second later, never inside the switch (Lawrence 2026-10-21, workspace switch speed of light: every
    /// switch encoded up to 256 stamps and wrote them on the main thread before the new workspace drew; main-actor
    /// jobs run before the run loop's Core Animation commit, so a yield alone would still write before the frame).
    /// A crash inside the delay loses a hover card's "since you looked" stamp, nothing more.
    private func save() {
        guard defaults != nil else { return }
        saveTimer.scheduleIfIdle(after: .milliseconds(500)) { @MainActor [weak self] in self?.flush() }
    }

    /// Writes the stamps now (a pending coalesced write, or a test that reads the defaults back).
    public func flush() {
        saveTimer.cancel()
        guard let defaults, let data = try? JSONEncoder().encode(stamps) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
