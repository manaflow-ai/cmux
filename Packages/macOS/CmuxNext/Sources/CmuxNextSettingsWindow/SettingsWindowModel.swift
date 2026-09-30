public import CmuxNextActions
public import CmuxNextSettings
public import Observation

/// The Settings window's state. Values come from `SettingsController`
/// (cmux.json, reloaded by the file watcher, so an edit in another editor
/// shows here at once); an edit writes the file and shows the new value
/// optimistically until the watcher's reload confirms it.
@MainActor
@Observable
public final class SettingsWindowModel {
    public let settings: SettingsController
    public let registry: ActionRegistry
    @ObservationIgnored public weak var host: (any SettingsWindowHost)?
    public var selection: SettingsSection = .general
    /// Search across every section and every shortcut.
    public var query = ""
    /// The last failed write, shown at the top of the detail.
    public var writeError: String?
    /// The shortcut being recorded (Keyboard section).
    public internal(set) var recorder: ShortcutRecorderState?
    /// The recorder's last result, on the row it edited.
    public internal(set) var notice: SettingsNotice?

    /// Values written but not yet read back from the file, by key.
    private var pending: [String: JSONValue?] = [:]
    @ObservationIgnored private var latest: [String: JSONValue?] = [:]
    @ObservationIgnored private var writing: Set<String> = []
    @ObservationIgnored private var activeDrains = 0
    @ObservationIgnored private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private(set) lazy var shortcutRecorder = ShortcutRecorder(
        registry: registry,
        state: { [weak self] in self?.recorder },
        setState: { [weak self] in self?.recorder = $0 },
        didFinish: { [weak self] id, text in self?.notice = text.map { SettingsNotice(actionID: id, text: $0) } })

    public init(settings: SettingsController, registry: ActionRegistry, host: (any SettingsWindowHost)?) {
        self.settings = settings
        self.registry = registry
        self.host = host
    }

    public var root: JSONValue { settings.snapshot.root }

    // MARK: Values

    /// What applies now: a pending edit, else the file's valid value, else the default.
    public func value(_ descriptor: SettingDescriptor) -> JSONValue? {
        if let edit = pending[descriptor.id] { return edit ?? descriptor.defaultValue }
        return descriptor.effectiveValue(in: root)
    }

    /// Whether the key is set in the file (pending edits included).
    public func isCustomized(_ descriptor: SettingDescriptor) -> Bool {
        if let edit = pending[descriptor.id] { return edit != nil && edit != descriptor.defaultValue }
        return descriptor.isCustomized(in: root)
    }

    /// The load diagnostic for this key, when the file holds a bad value.
    public func diagnostic(_ descriptor: SettingDescriptor) -> String? {
        settings.diagnostics.first { $0.path == descriptor.id || $0.path.hasPrefix(descriptor.id + ".") }?.message
    }

    /// Writes `value` (nil resets the key). Bursts (a slider drag, the color
    /// panel) coalesce: one write runs at a time per key and the next one
    /// takes the latest value, so the file sees at most one stale write.
    public func set(_ descriptor: SettingDescriptor, _ value: JSONValue?) {
        pending[descriptor.id] = .some(value)
        latest[descriptor.id] = .some(value)
        guard !writing.contains(descriptor.id) else { return }
        writing.insert(descriptor.id)
        activeDrains += 1
        Task {
            await drain(descriptor)
            activeDrains -= 1
            if activeDrains == 0 {
                let waiters = idleWaiters
                idleWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }
    }

    /// Returns once every write so far is in the file and read back.
    public func settled() async {
        guard activeDrains > 0 else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    private func drain(_ descriptor: SettingDescriptor) async {
        while let next = latest.removeValue(forKey: descriptor.id) {
            do {
                try await settings.setSetting(descriptor, to: next)
                writeError = nil
            } catch {
                writeError = SettingsWindowStrings.writeFailed(String(describing: error))
            }
        }
        writing.remove(descriptor.id)
        // Read the file back so `root` holds what was written, then drop
        // the optimistic value (unless a newer edit arrived meanwhile).
        await settings.reload()
        if latest[descriptor.id] == nil, !writing.contains(descriptor.id) { pending[descriptor.id] = nil }
    }

    /// Advanced > Reset All Settings.
    public func resetAll() {
        Task {
            do {
                try await settings.resetAllSettings()
                writeError = nil
            } catch {
                writeError = SettingsWindowStrings.writeFailed(String(describing: error))
            }
            await settings.reload()
        }
    }

    // MARK: Layout

    /// The section's settings in display order, grouped by heading.
    public func groups(in section: SettingsSection) -> [SettingsGroup] {
        Self.grouped(SettingsSchema.settings(in: section))
    }

    /// Settings matching `query` in every section (empty without a query).
    public func searchResults() -> [SettingsGroup] {
        let words = Self.words(query)
        guard !words.isEmpty else { return [] }
        let matches = SettingsSchema.all.filter { descriptor in
            let haystack = ([descriptor.title, descriptor.help ?? "", descriptor.group, descriptor.section.title, descriptor.id]
                + descriptor.keywords).joined(separator: " ")
            return words.allSatisfy { haystack.localizedStandardContains($0) }
        }
        return SettingsSection.allCases.flatMap { section in
            Self.grouped(matches.filter { $0.section == section }).map {
                SettingsGroup(title: "\(section.title) › \($0.title)", settings: $0.settings)
            }
        }
    }

    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func grouped(_ settings: [SettingDescriptor]) -> [SettingsGroup] {
        var groups: [SettingsGroup] = []
        for descriptor in settings {
            if groups.last?.title == descriptor.group {
                groups[groups.count - 1].settings.append(descriptor)
            } else {
                groups.append(SettingsGroup(title: descriptor.group, settings: [descriptor]))
            }
        }
        return groups
    }

    // MARK: Actions

    /// Runs a registry action (a section's buttons). False when unavailable.
    @discardableResult
    public func perform(_ id: ActionID) -> Bool { registry.perform(id) }

    public func actionTitle(_ id: ActionID) -> String? { registry.descriptor(for: id)?.title }
}

/// A heading and its rows.
public struct SettingsGroup: Identifiable, Hashable, Sendable {
    public var title: String
    public var settings: [SettingDescriptor]
    public var id: String { title }
}

/// The recorder's result, shown on the row it edited.
public struct SettingsNotice: Equatable, Sendable {
    public let actionID: ActionID
    public let text: String
}
