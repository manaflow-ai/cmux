public import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextFloating
public import CmuxNextSettings

/// The Chief pet's rows in the Chief Settings popover's Appearance section (Leo 2026-10-19: "pet
/// needs those settings to be obviously there"): Show Chief Pet (`home.chiefPetEnabled`) and the
/// popover's Chief's character, all nine pixel mascots at once, one click to swap (Leo 2026-10-21, as
/// ChatGPT swaps its avatars). The pick is that Chief's alone (``ChiefMascotPicks``): the default Chief's
/// is `home.chiefPetMascot`, read and written through the same `SettingsController` as Settings > Chief >
/// Chief Pet, so a change in either shows in the other (a managed key's control is disabled, as on the
/// Settings page); another Chief's is its own. Picking a character never shows the pet.
@MainActor
public final class ChiefPetSettingsRows: NSObject {
    let toggle = NSSwitch()
    let mascot = ChiefPetMascotGrid(items: ChiefPetSettingsRows.mascotItems())
    private let settings: @MainActor @Sendable () -> SettingsController?
    private let picks: ChiefMascotPicks
    private var watch: OwnedTask?
    /// The character last shown, for `onMascot`.
    private var shownMascot: String?
    private(set) weak var host: NSView?
    private var opener: (@MainActor () -> Bool)?
    /// The app's popovers the pet's Chief Pet Settings… opens; `install` adds these rows.
    private let homes: ChiefPetHomes
    /// Runs when this Chief's character is first read and each time it changes: the Home header
    /// wears it when its Chief has no avatar of its own.
    public var onMascot: (@MainActor () -> Void)?
    /// The participant id of the Chief whose popover these rows are in (nil: the default Chief); a
    /// new one shows its character, and the rows follow that Chief's inputs from then on.
    public var chief: String? {
        didSet { if chief != oldValue, host != nil { follow() } }
    }

    /// What the rows show: the two settings and whether each is managed.
    nonisolated struct Shown: Equatable, Sendable {
        var enabled: Bool
        var mascot: String
        var enabledManaged: Bool
        var mascotManaged: Bool
    }

    /// - Parameter picks: each Chief's character (the app's one ``ChiefMascotPicks``).
    public init(settings: @escaping @MainActor @Sendable () -> SettingsController?, homes: ChiefPetHomes,
                picks: ChiefMascotPicks) {
        self.settings = settings
        self.homes = homes
        self.picks = picks
        super.init()
        toggle.controlSize = .small
        toggle.target = self
        toggle.action = #selector(toggled)
        toggle.setAccessibilityIdentifier("cmux.home.chief.petEnabled")
        mascot.onPick = { [weak self] id in self?.pick(id) }
    }

    /// Adds Show Chief Pet and the pet's character through `addRow` (the Chief Settings
    /// popover's Appearance section) in `host`, then follows the settings while the rows live. `open`
    /// opens (never closes) that popover; false when `host` cannot show it.
    public func install(in host: NSView, addRow: (String, NSView) -> Void, open: @escaping @MainActor () -> Bool) {
        self.host = host
        self.opener = open
        homes.live.add(self)
        let enabledTitle = SettingsSchema.descriptor(for: HomeChiefPetSetting.configPath)?.title ?? ""
        toggle.setAccessibilityLabel(enabledTitle)
        addRow(enabledTitle, toggle)
        addRow(ChiefPetMascot.pickerTitle, mascot)
        follow()
    }

    /// Shows the settings and `chief`'s character now and on each change, until the next `follow`.
    /// The default Chief's character is a setting and another's a pick, so what is observed depends
    /// on the Chief (`chief` itself is not observable): a new Chief starts a new watch.
    private func follow() {
        watch?.cancel()
        let chief = chief, settings = settings, picks = picks
        // task-owner: lives until the rows' Chief changes or the rows go (their Home view; releasing it cancels it); event-driven (Observation)
        watch = OwnedTask(Task { [weak self] in
            // Every change is shown (a trigger, never deduplicated): `show` compares with what it showed.
            for await shown in ObservationStream({ ObservationTrigger(Self.shown(settings(), picks: picks, chief: chief)) }) {
                guard let self, !Task.isCancelled else { return }
                if let shown = shown.value { show(shown) }
            }
        })
        if let shown = Self.shown(settings(), picks: picks, chief: chief) { show(shown) }
    }

    // cx-t7hu: nonisolated, so a release (inside an action's task-local scope, or off the main
    // thread) runs no runtime hop; an implicit deinit is isolated in this target. The watch (an
    // OwnedTask) is cancelled on the releasing thread.
    nonisolated deinit {}

    /// The rows' state from the loaded settings and Chief `chief`'s pick. A managed
    /// `home.chiefPetMascot` locks the default Chief's character only.
    static func shown(_ settings: SettingsController?, picks: ChiefMascotPicks, chief: String?) -> Shown? {
        guard let settings else { return nil }
        let snapshot = settings.snapshot
        return Shown(enabled: snapshot.homeChiefPetEnabled, mascot: picks.mascot(of: chief, in: snapshot),
                     enabledManaged: settings.managedKeys[HomeChiefPetSetting.configPath.joined(separator: ".")] != nil,
                     mascotManaged: picks.isDefault(chief)
                         && settings.managedKeys[HomeChiefPetSetting.mascotPath.joined(separator: ".")] != nil)
    }

    func show(_ shown: Shown) {
        toggle.state = shown.enabled ? .on : .off
        toggle.isEnabled = !shown.enabledManaged
        mascot.select(shown.mascot, enabled: !shown.mascotManaged)
        if shown.mascot != shownMascot {
            shownMascot = shown.mascot
            onMascot?()
        }
    }

    /// One click on a character: the default Chief's goes to `home.chiefPetMascot`, another Chief's
    /// to its own pick.
    private func pick(_ id: String) {
        guard !picks.isDefault(chief), let chief else { return write(HomeChiefPetSetting.mascotPath, .string(id)) }
        picks.remember(id, for: chief)
    }

    /// The avatar picture of the character `mascot` names (an unknown or nil id: the first, orb):
    /// the whole character on a transparent square, for a Chief with no avatar of its own.
    public static func avatarURL(of mascot: String?) -> URL? {
        (ChiefPetMascot(rawValue: mascot ?? "") ?? .initial).avatarURL
    }

    /// Each mascot id with its name as the Settings page shows it (the schema's choice titles).
    static func mascotItems() -> [(id: String, title: String)] {
        guard case .choice(let choices)? = SettingsSchema.descriptor(for: HomeChiefPetSetting.mascotPath)?.kind else {
            return HomeChiefPetSetting.mascots.map { ($0, $0) }
        }
        return choices.map { ($0.value, $0.title) }
    }

    /// The mascot fit in a `side`-point square, its aspect kept (the bundled PNGs are 256 px wide).
    static func thumbnail(_ image: NSImage, side: CGFloat) -> NSImage {
        let copy = (image.copy() as? NSImage) ?? image
        let scale = min(side / max(image.size.width, 1), side / max(image.size.height, 1))
        copy.size = NSSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        return copy
    }

    @objc func toggled() {
        write(HomeChiefPetSetting.configPath, .bool(toggle.state == .on))
    }

    /// One cmux.json write, as the Settings page's control makes it; the file watcher then
    /// applies it everywhere (the pet, the Settings page, this popover). A refused write puts
    /// the rows back to what the settings hold.
    private func write(_ path: [String], _ value: CmuxNextSettings.JSONValue) {
        guard let settings = settings() else { return }
        // task-owner: one settings write; ends with it
        Task { [weak self] in
            do {
                try await settings.setSetting(at: path, to: value, by: .user)
            } catch {
                NSSound.beep()
                if let self, let shown = Self.shown(settings, picks: picks, chief: chief) { show(shown) }
            }
        }
    }

    /// Opens this Home's popover and brings its window forward (`ChiefPetHomes.open`); false off screen.
    func openOnScreen(noActivate: Bool) -> Bool {
        guard let host, let window = host.window, window.isVisible, !window.isMiniaturized, !host.isHiddenOrHasHiddenAncestor,
              let opener, opener() else { return false }
        WindowActivation.show(window, noActivate ? .raise : .focus)
        return true
    }
}
