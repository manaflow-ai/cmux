public import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextFloating
public import CmuxNextSettings

/// The Chief pet's rows in the Chief Settings popover's Appearance section (Leo 2026-10-19: "pet
/// needs those settings to be obviously there"): Show Chief Pet (`home.chiefPetEnabled`) and the
/// pet's character (`home.chiefPetMascot`), each pixel mascot drawn beside its name. They read
/// and write the same `SettingsController` as Settings > Chief > Chief Pet, so a change in
/// either shows in the other; a managed key's control is disabled, as on the Settings page.
@MainActor
public final class ChiefPetSettingsRows: NSObject {
    /// The menu's mascot pictures: the pixel character at a menu row's height.
    static let thumbnailSize = NSSize(width: 18, height: 18)

    let toggle = NSSwitch()
    let mascot = ThemedPopUpButton(frame: .zero, pullsDown: false)
    private let settings: @MainActor @Sendable () -> SettingsController?
    private var watch: Task<Void, Never>?
    private(set) weak var host: NSView?
    private var opener: (@MainActor () -> Bool)?
    /// The app's popovers the pet's Chief Pet Settings… opens; `install` adds these rows.
    private let homes: ChiefPetHomes
    /// Runs when the chosen character (`home.chiefPetMascot`) is first read and each time it
    /// changes: the Home header wears it when its Chief has no avatar of its own.
    public var onMascot: (@MainActor () -> Void)?

    /// What the rows show: the two settings and whether each is managed.
    nonisolated struct Shown: Equatable, Sendable {
        var enabled: Bool
        var mascot: String
        var enabledManaged: Bool
        var mascotManaged: Bool
    }

    public init(settings: @escaping @MainActor @Sendable () -> SettingsController?, homes: ChiefPetHomes) {
        self.settings = settings
        self.homes = homes
        super.init()
        toggle.controlSize = .small
        toggle.target = self
        toggle.action = #selector(toggled)
        toggle.setAccessibilityIdentifier("cmux.home.chief.petEnabled")
        mascot.font = Typography.body
        mascot.target = self
        mascot.action = #selector(pickedMascot)
        mascot.setAccessibilityIdentifier("cmux.home.chief.petMascot")
        for (id, title) in Self.mascotItems() {
            mascot.addItem(withTitle: title)
            mascot.lastItem?.representedObject = id
            mascot.lastItem?.image = ChiefPetMascot(rawValue: id)?.image.map(Self.thumbnail)
        }
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
        mascot.setAccessibilityLabel(ChiefPetMascot.pickerTitle)
        addRow(enabledTitle, toggle)
        addRow(ChiefPetMascot.pickerTitle, mascot)
        // task-owner: lives as long as the rows (their Home view; deinit cancels it); event-driven (Observation)
        watch = Task { [weak self] in
            guard let settings = self?.settings else { return }
            var mascot: String?
            for await shown in ObservationStream({ Self.shown(settings()) }) {
                guard let self else { return }
                guard let shown else { continue }
                show(shown)
                if shown.mascot != mascot {
                    mascot = shown.mascot
                    onMascot?()
                }
            }
        }
    }

    // As HomeHostView's: not an isolated deinit; the watch ends with the rows (their Home view).
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated { watch?.cancel() }
    }

    /// The rows' state from the loaded settings (what the Settings page shows).
    static func shown(_ settings: SettingsController?) -> Shown? {
        guard let settings else { return nil }
        let snapshot = settings.snapshot
        return Shown(enabled: snapshot.homeChiefPetEnabled, mascot: snapshot.homeChiefPetMascot,
                     enabledManaged: settings.managedKeys[HomeChiefPetSetting.configPath.joined(separator: ".")] != nil,
                     mascotManaged: settings.managedKeys[HomeChiefPetSetting.mascotPath.joined(separator: ".")] != nil)
    }

    func show(_ shown: Shown) {
        toggle.state = shown.enabled ? .on : .off
        toggle.isEnabled = !shown.enabledManaged
        let index = mascot.itemArray.firstIndex { $0.representedObject as? String == shown.mascot } ?? 0
        mascot.selectItem(at: index)
        mascot.isEnabled = !shown.mascotManaged
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

    /// The mascot at a menu row's height, its aspect kept (the bundled PNGs are 256 px wide).
    static func thumbnail(_ image: NSImage) -> NSImage {
        let copy = (image.copy() as? NSImage) ?? image
        let scale = min(thumbnailSize.width / max(image.size.width, 1), thumbnailSize.height / max(image.size.height, 1))
        copy.size = NSSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        return copy
    }

    @objc func toggled() {
        write(HomeChiefPetSetting.configPath, .bool(toggle.state == .on))
    }

    @objc func pickedMascot() {
        guard let id = mascot.selectedItem?.representedObject as? String else { return }
        write(HomeChiefPetSetting.mascotPath, .string(id))
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
                if let self, let shown = Self.shown(settings) { show(shown) }
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
