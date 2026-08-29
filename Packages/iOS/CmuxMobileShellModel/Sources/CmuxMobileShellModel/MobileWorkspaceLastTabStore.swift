public import Foundation

/// The tab a workspace last showed on this device: a terminal, or a
/// non-terminal Mac surface.
public struct MobileWorkspaceLastTab: Hashable, Sendable {
    /// Which selection axis the remembered tab lives on.
    public enum Kind: String, Codable, Sendable {
        case terminal
        case macSurface
    }

    /// The remembered tab's selection axis.
    public var kind: Kind
    /// The raw terminal or surface identifier, Mac-local like the ids inside
    /// a workspace preview.
    public var tabID: String

    /// Creates a remembered tab.
    /// - Parameters:
    ///   - kind: Which selection axis the tab lives on.
    ///   - tabID: The raw terminal or surface identifier.
    public init(kind: Kind, tabID: String) {
        self.kind = kind
        self.tabID = tabID
    }
}

/// Device-local "last opened tab" memory per workspace, persisted in an
/// injected `UserDefaults`.
///
/// Which tab a workspace shows is a per-device UI preference, not shared
/// state: the Mac's focused pane keeps moving with Mac usage, and following
/// it on every open is exactly the behavior this store exists to override.
/// The map is keyed by ``MobileWorkspacePreview/lastTabStateID`` (Mac-scoped,
/// unlike the aggregate row id, which is only scoped while several Macs are
/// live) and bounded to ``maxEntries`` by dropping the least recently
/// updated workspaces.
///
/// The backing `UserDefaults` is injected so the store is testable without
/// touching `.standard` (mirroring `MobileWorkspaceGroupCollapseStore`); the
/// app constructs it at the composition root with `UserDefaults.standard`,
/// previews and tests use ``inMemory``.
public struct MobileWorkspaceLastTabStore: Sendable {
    /// The defaults key under which the `[lastTabStateID: entry]` map is stored.
    public static let defaultsKey = "dev.cmux.mobile.workspace.lastTab.v1"
    /// Upper bound on remembered workspaces; the least recently updated
    /// entries are dropped first.
    public static let maxEntries = 512

    private struct Entry: Codable, Sendable {
        var kind: MobileWorkspaceLastTab.Kind
        var tabID: String
        /// Monotonic recency stamp (not wall-clock), so pruning order is
        /// deterministic even for writes within one instant.
        var seq: UInt64
    }

    // UserDefaults is Apple-documented thread-safe; OK to hold nonisolated.
    // `nil` = in-memory only (previews/tests).
    private nonisolated(unsafe) let defaults: UserDefaults?
    private var map: [String: Entry]
    private var nextSeq: UInt64

    /// Create a store backed by the given defaults.
    /// - Parameter defaults: The persistence store for the last-tab map.
    ///   Inject a suite-scoped `UserDefaults` in tests; the app passes
    ///   `.standard`; `nil` keeps the map in memory only.
    public init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        if let data = defaults?.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            map = decoded
        } else {
            map = [:]
        }
        nextSeq = (map.values.map(\.seq).max() ?? 0) &+ 1
    }

    /// A store that never persists, for previews and tests.
    public static var inMemory: Self { .init(defaults: nil) }

    /// The tab this workspace last showed on this device, or `nil` if none
    /// was recorded (or it was pruned).
    public func lastTab(for workspaceStateID: String) -> MobileWorkspaceLastTab? {
        guard let entry = map[workspaceStateID] else { return nil }
        return MobileWorkspaceLastTab(kind: entry.kind, tabID: entry.tabID)
    }

    /// Record the tab a workspace currently shows. Persists immediately;
    /// re-recording the unchanged tab is a no-op (no write, no recency bump).
    public mutating func set(_ tab: MobileWorkspaceLastTab, for workspaceStateID: String) {
        if let existing = map[workspaceStateID],
           existing.kind == tab.kind, existing.tabID == tab.tabID {
            return
        }
        map[workspaceStateID] = Entry(kind: tab.kind, tabID: tab.tabID, seq: nextSeq)
        nextSeq &+= 1
        if map.count > Self.maxEntries {
            let oldestKeys = map.sorted { $0.value.seq < $1.value.seq }
                .prefix(map.count - Self.maxEntries)
                .map(\.key)
            for key in oldestKeys {
                map.removeValue(forKey: key)
            }
        }
        persist()
    }

    private func persist() {
        guard let defaults else { return }
        if let data = try? JSONEncoder().encode(map) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
