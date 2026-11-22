public import AppKit
public import CmuxNextDesign
public import Observation

/// What the Debug Settings list shows.
public enum DebugSettingsSelection: Hashable, Sendable {
    case all
    /// Tunables that differ from their defaults.
    case changed
    case section(String)
}

/// The Debug Settings window's state over the tunable store: search,
/// sidebar selection, edits, resets and the hand-off exports. Values are
/// read from the store (per-key Observation), so the window and the app
/// update together.
@MainActor
@Observable
public final class DebugSettingsModel {
    @ObservationIgnored public let store: TunableStore
    /// Every tunable, sorted by section then registration order.
    @ObservationIgnored public let descriptors: [TunableDescriptor]
    public var query = ""
    public var selection: DebugSettingsSelection = .all
    /// The last export or reset, shown under the toolbar.
    public var notice: String?
    /// Bumped by Cmd-F; the search field takes focus when it changes.
    public var searchFocusRequest = 0

    public init(store: TunableStore, descriptors: [TunableDescriptor]) {
        self.store = store
        let indexed = Dictionary(descriptors.enumerated().map { ($1.key, $0) }, uniquingKeysWith: { first, _ in first })
        self.descriptors = descriptors.sorted {
            ($0.section.order, indexed[$0.key] ?? 0) < ($1.section.order, indexed[$1.key] ?? 0)
        }
    }

    // MARK: Lists

    public var sections: [TunableSection] {
        var seen = Set<String>()
        return descriptors.map(\.section).filter { seen.insert($0.id).inserted }
    }

    public func count(in section: TunableSection) -> Int { descriptors.count { $0.section.id == section.id } }

    public func changedCount(in section: TunableSection) -> Int {
        let overrides = store.overrides
        return descriptors.count { $0.section.id == section.id && isChanged($0, overrides: overrides) }
    }

    public var changedCount: Int {
        let overrides = store.overrides
        return descriptors.count { isChanged($0, overrides: overrides) }
    }

    /// The rows to show: a search looks through every tunable; otherwise
    /// the selected section, every tunable, or the changed ones.
    public var visible: [TunableDescriptor] {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            let matches = TunableSearch.filter(descriptors, query: query)
            guard selection == .changed else { return matches }
            let overrides = store.overrides
            return matches.filter { isChanged($0, overrides: overrides) }
        }
        switch selection {
        case .all: return descriptors
        case .changed:
            let overrides = store.overrides
            return descriptors.filter { isChanged($0, overrides: overrides) }
        case .section(let id): return descriptors.filter { $0.section.id == id }
        }
    }

    /// `visible`, grouped under section headers in sidebar order.
    public var groupedVisible: [(section: TunableSection, rows: [TunableDescriptor])] {
        let rows = visible
        return sections.compactMap { section in
            let members = rows.filter { $0.section.id == section.id }
            return members.isEmpty ? nil : (section, members)
        }
    }

    // MARK: Values

    /// The override, else the default.
    public func value(_ descriptor: TunableDescriptor) -> TunableValue {
        store.override(descriptor.key) ?? descriptor.defaultValue
    }

    /// Whether the tunable differs from its default.
    public func isChanged(_ descriptor: TunableDescriptor) -> Bool {
        guard let value = store.override(descriptor.key) else { return false }
        return value != descriptor.defaultValue
    }

    private func isChanged(_ descriptor: TunableDescriptor, overrides: [String: TunableValue]) -> Bool {
        guard let value = overrides[descriptor.key] else { return false }
        return value != descriptor.defaultValue
    }

    /// Sets a value (clamped by the store). Setting the default removes the
    /// override, so "changed" stays exact.
    public func set(_ descriptor: TunableDescriptor, _ value: TunableValue) {
        notice = nil
        if descriptor.clamp(value) == descriptor.defaultValue {
            store.reset([descriptor.key])
        } else {
            store.set(descriptor.key, value)
        }
    }

    public func reset(_ descriptor: TunableDescriptor) {
        store.reset([descriptor.key])
    }

    public func reset(section: TunableSection) {
        store.reset(descriptors.filter { $0.section.id == section.id }.map(\.key))
        notice = DebugSettingsStrings.didReset(section.title)
    }

    public func resetAll() {
        store.resetAll()
        notice = DebugSettingsStrings.didResetAll
    }

    // MARK: Export

    public var changes: [TunableExport.Change] { TunableExport.changes(descriptors: descriptors, overrides: store.overrides) }

    /// Puts the changed values on the pasteboard as JSON; returns the text.
    @discardableResult
    public func copyJSON(to pasteboard: NSPasteboard? = .general) -> String {
        let changes = changes
        let text = TunableExport.json(changes)
        write(text, to: pasteboard)
        notice = changes.isEmpty ? DebugSettingsStrings.nothingChanged : DebugSettingsStrings.copiedJSON(changes.count)
        return text
    }

    /// Puts the changed values on the pasteboard as Swift defaults.
    @discardableResult
    public func copySwift(to pasteboard: NSPasteboard? = .general) -> String {
        let changes = changes
        let text = TunableExport.swiftDefaults(changes)
        write(text, to: pasteboard)
        notice = changes.isEmpty ? DebugSettingsStrings.nothingChanged : DebugSettingsStrings.copiedSwift(changes.count)
        return text
    }

    private func write(_ text: String, to pasteboard: NSPasteboard?) {
        guard let pasteboard else { return }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// The section a selection names, if any.
    public var selectedSection: TunableSection? {
        guard case .section(let id) = selection else { return nil }
        return sections.first { $0.id == id }
    }
}
