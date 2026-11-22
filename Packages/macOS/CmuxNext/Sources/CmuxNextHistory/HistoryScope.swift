public import Foundation

/// What Back and Forward walk (`navigation.historyScope`; plans/cmux-next/history.md 4.2a, R69).
public nonisolated enum HistoryScope: String, CaseIterable, Hashable, Sendable, Codable {
    /// Trail entries of the current workspace (same machine and workspace key). The default.
    case workspace
    /// Trail entries recorded in the current window, across its workspaces.
    case window
    /// The focused surface's own list (a browser page's back/forward); no trail entry.
    case surface

    public static let `default` = HistoryScope.workspace

    /// Whether `location` is a place Back and Forward may reach from `current` under `scope`.
    public static func contains(_ location: HistoryLocation, current: HistoryLocation, scope: HistoryScope) -> Bool {
        // A top page belongs to no workspace: it is in the scope of its window's trail.
        if scope != .surface, location.page != nil || current.page != nil { return location.window == current.window }
        return switch scope {
        case .workspace: location.key.machine == current.key.machine && location.workspace == current.workspace
        case .window: location.window == current.window
        case .surface: false
        }
    }
}

/// A Back or Forward list row: the trail index (for ``LocationTrail/go(to:)``) and its entry.
public nonisolated struct LocationTrailListItem: Hashable, Sendable {
    public let index: Int
    public let entry: LocationTrail.Entry

    public init(index: Int, entry: LocationTrail.Entry) {
        self.index = index
        self.entry = entry
    }
}

public nonisolated enum LocationTrailDirection: Sendable, Hashable {
    case back
    case forward
}

extension LocationTrail {
    /// Back within `scope` (see ``HistoryScope``); entries out of scope are kept, never returned.
    public mutating func back(scope: HistoryScope, isAvailable: (HistoryLocation) -> Bool = { _ in true }) -> Entry? {
        guard let current = current?.location else { return nil }
        return back { isAvailable($0) && HistoryScope.contains($0, current: current, scope: scope) }
    }

    /// Forward within `scope`.
    public mutating func forward(scope: HistoryScope, isAvailable: (HistoryLocation) -> Bool = { _ in true }) -> Entry? {
        guard let current = current?.location else { return nil }
        return forward { isAvailable($0) && HistoryScope.contains($0, current: current, scope: scope) }
    }

    /// Go to Last Location within `scope`.
    public mutating func last(scope: HistoryScope, isAvailable: (HistoryLocation) -> Bool = { _ in true }) -> Entry? {
        guard let current = current?.location else { return nil }
        return last { isAvailable($0) && HistoryScope.contains($0, current: current, scope: scope) }
    }

    public func canGoBack(scope: HistoryScope, isAvailable: (HistoryLocation) -> Bool = { _ in true }) -> Bool {
        guard let current = current?.location else { return false }
        return canGoBack { isAvailable($0) && HistoryScope.contains($0, current: current, scope: scope) }
    }

    public func canGoForward(scope: HistoryScope, isAvailable: (HistoryLocation) -> Bool = { _ in true }) -> Bool {
        guard let current = current?.location else { return false }
        return canGoForward { isAvailable($0) && HistoryScope.contains($0, current: current, scope: scope) }
    }

    /// The long-press / right-click list of a Back or Forward button: in-scope entries before (Back)
    /// or after (Forward) the cursor, nearest first, without repeats of the current location.
    public func list(_ direction: LocationTrailDirection, scope: HistoryScope,
                     isAvailable: (HistoryLocation) -> Bool = { _ in true }) -> [LocationTrailListItem] {
        guard let current = current?.location, cursor >= 0 else { return [] }
        let indices: [Int] = direction == .back ? Array((0..<cursor).reversed()) : Array((cursor + 1)..<entries.count)
        return indices.compactMap { index in
            let location = entries[index].location
            guard location.key != current.key, isAvailable(location),
                  HistoryScope.contains(location, current: current, scope: scope) else { return nil }
            return LocationTrailListItem(index: index, entry: entries[index])
        }
    }
}
