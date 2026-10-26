public import CmuxNextActions
public import CmuxNextCompat
public import CmuxNextDesign

/// `memory.saver` in cmux-next.json: how hard cmux trims memory it can recreate, by Chrome's four
/// Memory Saver modes (``MemorySaverMode``).
///
/// ```jsonc
/// "memory": {
///   "saver": "medium"   // "off" | "conservative" | "medium" | "aggressive"
/// }
/// ```
///
/// The mode sets the memory coordinator's share for managed caches under pressure (100, 75, 50 or
/// 25 %) and how long hidden content of the newer kinds (page tabs, conversations, parked
/// workspaces) waits before a proactive discard (1.5x, 1x or 0.5x of its own timeout; off: none).
/// Chrome's `chrome/browser/performance_manager/policies/memory_saver_mode_policy.cc` and
/// `memory_saver_memory_coordinator_policy.h`. Medium, the default, is what cmux did before the
/// setting. `browser.hibernation` stays the browser's own setting: browser tabs follow it, not this.
///
/// Read from the snapshot's document, not stored: a missing or unknown value is the default.
public nonisolated struct MemorySaverSetting: Sendable {
    /// The cmux-next.json key path.
    public static let path = ["memory", "saver"]
    /// Chrome's default mode, and the timeouts cmux shipped before the setting.
    public static let defaultValue: MemorySaverMode = .medium

    /// Makes the value from its parts.
    public init() {}

    /// The mode in `root`: the default when the key is missing or names no mode.
    public func value(in root: JSONValue) -> MemorySaverMode {
        root.value(at: Self.path)?.stringValue.flatMap(MemorySaverMode.init(rawValue:)) ?? Self.defaultValue
    }

    /// The cmux-next.json value of `mode`: the default removes the key.
    public static func fileValue(_ mode: MemorySaverMode) -> JSONValue? {
        mode == defaultValue ? nil : .string(mode.rawValue)
    }
}

extension CmuxConfigSnapshot {
    /// `memory.saver` (``MemorySaverSetting``).
    public var memorySaver: MemorySaverMode { MemorySaverSetting().value(in: root) }
}

extension MemorySaverSetting {
    /// Memory Saver's palette actions (`memory.saver.off|conservative|medium|aggressive`, catalog
    /// `MemorySaverActionCatalog`), each bound with `bindEffect`: `save` refuses a managed key before
    /// anything changes, else starts the cmux-next.json write (the default removes the key), then
    /// `apply` hands the mode to the memory coordinator in the action's own turn. Each returns
    /// `.done`: the mode is set, and every planner that follows it looks again on its own deadline.
    ///
    /// - Parameters:
    ///   - registry: The app's action registry.
    ///   - save: The validated settings write; a refusal when the key is managed.
    ///   - apply: Sets the live mode (the App's `memoryCoordinator.mode`).
    @MainActor public static func bindActions(into registry: ActionRegistry, save: @escaping SettingChoiceActions.Save,
                                              apply: @escaping @MainActor (MemorySaverMode) -> Void) {
        for mode in MemorySaverMode.allCases {
            registry.bindEffect(mode.actionID, effect: { _ in
                if let refusal = save(Self.path, Self.fileValue(mode)) { return .refused(refusal) }
                apply(mode)
                return .done
            })
        }
    }
}

/// Debug Settings' `memory.discard.<kind>` toggles (p07-memory.md 3.C): one per lossy discard kind that
/// ships behind a default-off feature. Each toggle is its feature's local override (the feature's
/// `replaces`, FeatureList step 3: DEV and NIGHTLY, below policy and the environment), read at launch as
/// Chrome reads its about:flags entries (components/flags_ui), so a change applies at the next launch.
/// Off by default, as every feature they override; Release and RC never activate the store. English
/// developer text, as every Debug Settings section.
public nonisolated struct MemoryDiscardToggles: Sendable {
    public init() {}

    public static let section = TunableSection(id: "memoryDiscard", title: "Memory Saver Discards", symbol: "memorychip", order: 49)

    public static let internalPages = Tunable<Bool>.toggle(
        "memory.discard.internalPages", section, "Discard hidden page tabs",
        help: "Overrides memoryDiscardInternalPages: a page tab whose page declares a discard policy lets its view and page renderer go once hidden past it, and keeps its tab, route, scroll and picture. Applies at the next launch.",
        default: false, code: "MemoryDiscardToggles.internalPages")

    public static let topPages = Tunable<Bool>.toggle(
        "memory.discard.topPages", section, "Discard hidden top pages",
        help: "Overrides topPageDiscard: classic Home hidden past its timeout lets its view go and comes back with its conversation, search and scroll. Applies at the next launch.",
        default: false, code: "MemoryDiscardToggles.topPages")

    public static let conversations = Tunable<Bool>.toggle(
        "memory.discard.conversations", section, "Discard hidden conversations",
        help: "Overrides memoryDiscardConversations: a conversation tab hidden past its timeout drops its transcript rows and images and keeps its scroll and draft. Applies at the next launch.",
        default: false, code: "MemoryDiscardToggles.conversations")

    public static let parkedWorkspaces = Tunable<Bool>.toggle(
        "memory.discard.parkedWorkspaces", section, "Hold parked workspaces to the budget",
        help: "Overrides memoryDiscardParkedWorkspaces: at most this Mac's budget of hidden workspaces stay mounted across all windows; past it the least recently parked one lets its views go. Applies at the next launch.",
        default: false, code: "MemoryDiscardToggles.parkedWorkspaces")

    public static let pageTabs = Tunable<Bool>.toggle(
        "memory.discard.pageTabs", section, "Hibernate cmux page tabs",
        help: "Overrides memoryDiscardPageTabs: cmux pages in browser tabs (History, Bookmarks, Vault and others) hibernate like web pages. Applies at the next launch.",
        default: false, code: "MemoryDiscardToggles.pageTabs")

    public static let remoteTabs = Tunable<Bool>.toggle(
        "memory.discard.remoteTabs", section, "Hibernate remote tabs",
        help: "Overrides memoryDiscardRemoteTabs: a hidden remote desktop or remote browser tab closes its stream and decoder past the hibernation timeout. Applies at the next launch.",
        default: false, code: "MemoryDiscardToggles.remoteTabs")

    public static let terminalGPURelease = Tunable<Bool>.toggle(
        "memory.discard.terminalGPURelease", section, "Release hidden terminals' GPU memory",
        help: "Overrides terminalGPURelease: a terminal hidden outside the keep-alive band lets its GPU memory go while paused. Needs a GhosttyNextKit with ghostty_surface_set_gpu_resident. Applies at the next launch.",
        default: false, code: "MemoryDiscardToggles.terminalGPURelease")

    /// Every toggle, in the Debug Settings order.
    public static let toggles = [internalPages, topPages, conversations, parkedWorkspaces, pageTabs, remoteTabs, terminalGPURelease]

    /// The descriptors Debug Settings lists.
    public static var all: [TunableDescriptor] { toggles.map(\.descriptor) }
}

/// The `memory.saver` row: Settings > General > Memory Saver. Off the Settings page while the kinds
/// whose timeouts it scales are behind their default-off features (`memory.discard.<kind>`); the
/// palette's Memory Saver actions, the export and agents reach it.
nonisolated enum MemorySettingsSchema {
    static var descriptors: [SettingDescriptor] {
        let group = SettingsText.keyed("settings.group.memorySaver", "Memory Saver")
        return [
            SettingDescriptor(
                MemorySaverSetting.path, section: .general, group: group,
                title: SettingsText.keyed("settings.memory.saver", "Memory Saver"),
                help: SettingsText.keyed(
                    "settings.memory.saver.help",
                    "Frees memory from hidden pages, conversations and workspaces you are not using. Moderate waits longest, Maximum frees memory soonest, and Balanced is in between. Off frees memory only when the Mac runs low on memory. Browser tabs follow Hibernate Hidden Tabs."),
                summary: SettingsText.keyed("settings.memory.saver.summary", "Free memory from content you are not using"),
                kind: .choice([
                    SettingChoice(MemorySaverMode.off.rawValue, SettingsText.keyed("settings.choice.off", "Off")),
                    SettingChoice(MemorySaverMode.conservative.rawValue, SettingsText.keyed("settings.choice.memory.conservative", "Moderate")),
                    SettingChoice(MemorySaverMode.medium.rawValue, SettingsText.keyed("settings.choice.memory.medium", "Balanced")),
                    SettingChoice(MemorySaverMode.aggressive.rawValue, SettingsText.keyed("settings.choice.memory.aggressive", "Maximum")),
                ]),
                default: .string(MemorySaverSetting.defaultValue.rawValue),
                keywords: ["memory", "memory saver", "ram", "discard", "hibernate", "sleep", "free memory", "performance"]
            )
            .hiddenFromSettingsPage("scales the timeouts of discard kinds behind default-off features (memory.discard.<kind>)"),
        ]
    }
}
