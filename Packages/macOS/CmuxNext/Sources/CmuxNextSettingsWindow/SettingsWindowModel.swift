public import CmuxNextActions
public import CmuxNextDesign
public import CmuxNextSettings
public import Observation

/// The Settings window's state. Values come from `SettingsController`
/// (cmux-next.json, reloaded by the file watcher, so an edit in another editor
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
    /// The last request to scroll to a row, card, button or header (a
    /// search result, Return in search, a deep link, a one-page sidebar
    /// click). The detail view scrolls when its serial changes.
    public internal(set) var jump: SettingsJump?
    /// The anchor id lit up after a jump, until its highlight ends.
    public internal(set) var highlighted: String?
    /// Pins speed and Reduce Motion for the highlight (tests); nil reads
    /// the live `Motion.policy`.
    @ObservationIgnored public var motionPolicyOverride: MotionPolicy?
    @ObservationIgnored var jumpSerial = 0

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

    /// Whether the key is set in the user's file (pending edits included).
    /// MDM recommended and team default values are not customizations.
    public func isCustomized(_ descriptor: SettingDescriptor) -> Bool {
        if isManaged(descriptor) { return false }
        if let edit = pending[descriptor.id] { return edit != nil && edit != descriptor.defaultValue }
        return descriptor.isCustomized(in: settings.fileRoot)
    }

    /// Whether an MDM profile or the team policy manages the key; its control is disabled.
    public func isManaged(_ descriptor: SettingDescriptor) -> Bool {
        settings.managedSource(for: descriptor) != nil
    }

    /// "Managed by your organization" or "Managed by <team>", nil when the user decides.
    public func managedNote(_ descriptor: SettingDescriptor) -> String? {
        switch settings.managedSource(for: descriptor) {
        case nil: nil
        case .device?: SettingsWindowStrings.managedByOrganization
        case .team(let name)?: name.isEmpty ? SettingsWindowStrings.managedByOrganization : SettingsWindowStrings.managedByTeam(name)
        }
    }

    /// The load diagnostic for this key, when the file holds a bad value.
    /// A managed key shows its managed note instead.
    public func diagnostic(_ descriptor: SettingDescriptor) -> String? {
        if isManaged(descriptor) { return nil }
        return settings.diagnostics.first { $0.path == descriptor.id || $0.path.hasPrefix(descriptor.id + ".") }?.message
    }

    /// Writes `value` (nil resets the key). Bursts (a slider drag, the color
    /// panel) coalesce: one write runs at a time per key and the next one
    /// takes the latest value, so the file sees at most one stale write.
    public func set(_ descriptor: SettingDescriptor, _ value: JSONValue?) {
        guard !isManaged(descriptor) else { return }
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

    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    static func grouped(_ settings: [SettingDescriptor]) -> [SettingsGroup] {
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

    /// Runs a registry action with a target and arguments (a browser
    /// profile's form).
    @discardableResult
    public func perform(_ id: ActionID, invocation: ActionInvocation) -> Bool { registry.perform(id, invocation: invocation) }

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
