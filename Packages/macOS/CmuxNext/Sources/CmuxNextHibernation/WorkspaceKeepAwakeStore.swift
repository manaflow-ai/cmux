public import Foundation

/// The workspaces the person keeps awake: workspace hibernation never takes them
/// (plans/cmux-next/workspace-hibernation-DESIGN.md). Per Mac, since memory is per Mac: one
/// `UserDefaults` array of workspace ids, written whole on each change (an atomic defaults write).
///
/// ```swift
/// let keepAwake = WorkspaceKeepAwakeStore(defaults: UserDefaults(suiteName: "test")!)
/// keepAwake.toggle("ws_1")   // true: now kept awake
/// ```
@MainActor
public final class WorkspaceKeepAwakeStore {
    // UserDefaults is Apple-documented thread-safe; only the main actor writes this key.
    private let defaults: UserDefaults
    private let key: String
    private var ids: Set<String>

    /// - Parameters:
    ///   - defaults: where the set lasts (tests pass a suite of their own).
    ///   - key: the defaults key.
    public init(defaults: UserDefaults, key: String = "cmux.workspaceHibernation.keepAwake") {
        self.defaults = defaults
        self.key = key
        ids = Set(defaults.stringArray(forKey: key) ?? [])
    }

    /// Whether `workspace` is kept awake.
    public func contains(_ workspace: String) -> Bool { ids.contains(workspace) }

    /// Every kept workspace.
    public var all: Set<String> { ids }

    /// Keeps `workspace` awake (true) or lets it hibernate again (false), and saves.
    public func set(_ workspace: String, keptAwake: Bool) {
        let changed = keptAwake ? ids.insert(workspace).inserted : ids.remove(workspace) != nil
        guard changed else { return }
        defaults.set(ids.sorted(), forKey: key)
    }

    /// Flips `workspace` and returns whether it is now kept awake.
    @discardableResult
    public func toggle(_ workspace: String) -> Bool {
        let now = !contains(workspace)
        set(workspace, keptAwake: now)
        return now
    }

    /// Drops ids of workspaces that no longer exist (`live`), so the set does not grow forever.
    public func keep(only live: Set<String>) {
        let kept = ids.intersection(live)
        guard kept.count != ids.count else { return }
        ids = kept
        defaults.set(ids.sorted(), forKey: key)
    }
}
