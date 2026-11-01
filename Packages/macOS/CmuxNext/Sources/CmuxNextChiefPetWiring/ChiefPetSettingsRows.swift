public import AppKit
import CmuxNextCompat
import CmuxNextDesign
public import CmuxNextFloating
public import CmuxNextSettings

/// The Chief pet's rows in the Chief Settings popover's Appearance section (Leo 2026-10-19: "pet
/// needs those settings to be obviously there"): Show Chief Pet (`home.chiefPetEnabled`) and the
/// popover's Chief's character, all nine pixel mascots at once, one click to swap (Leo 2026-10-21, as
/// ChatGPT swaps its avatars). The pick is that Chief's alone (``ChiefMascotPicks``): the default Chief's
/// is `home.chiefPetMascot`, read and written through the same `SettingsController` as Settings > Chief >
/// Chief Pet, so a change in either shows in the other (a managed key's control is disabled, as on the
/// Settings page); another Chief's is its own. Picking a character never shows the pet.
///
/// The person's own upload is that Chief's character too (``ChiefAvatarUploads``; Leo 2026-10-26:
/// "upload their own if they have things from elsewhere"): Upload Your Own… (the grid's "+" tile, a
/// file picker) or a picture dropped on the grid wears it, a click on a character wears that and keeps
/// the upload, and Remove Upload deletes it, so the character picked before shows again.
@MainActor
public final class ChiefPetSettingsRows: NSObject {
    let toggle = NSSwitch()
    let mascot = ChiefPetMascotGrid(items: ChiefPetSettingsRows.mascotItems())
    /// Upload Your Own… under the grid (``ChiefPetUploadAffordance/button``).
    let uploadButton = NSButton(title: ChiefAvatarUploads.chooseTitle, target: nil, action: nil)
    /// The drop hint under the grid (``ChiefPetUploadAffordance/drop``).
    let dropHint = ThemedLabel(wrappingLabelWithString: ChiefAvatarUploads.dropHint)
    private let settings: @MainActor @Sendable () -> SettingsController?
    private let picks: ChiefMascotPicks
    /// The person's own uploads; nil offers none.
    private let uploads: ChiefAvatarUploads?
    /// Why an upload was refused, in the person's words: the popover's note line shows it.
    public var onRefusal: (@MainActor (String) -> Void)?
    private var watch: Task<Void, Never>?
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

    /// What the rows show: the two settings, whether each is managed, and the Chief's upload.
    nonisolated struct Shown: Equatable, Sendable {
        var enabled: Bool
        var mascot: String
        var enabledManaged: Bool
        var mascotManaged: Bool
        var upload: ChiefAvatarUploads.Upload?
        /// How the grid offers an upload before there is one (``ChiefPetTunables/uploadAffordance``).
        var affordance = ChiefPetUploadAffordance.tile

        /// What the Chief wears: its worn upload, else its character.
        var face: String { isWorn ? upload?.still.path ?? mascot : mascot }
        /// Whether the upload is worn: worn over the character picked now.
        var isWorn: Bool { upload?.wornOver == mascot }
    }

    /// - Parameters:
    ///   - picks: each Chief's character (the app's one ``ChiefMascotPicks``).
    ///   - uploads: each Chief's own upload (the app's one ``ChiefAvatarUploads``); nil offers none.
    public init(settings: @escaping @MainActor @Sendable () -> SettingsController?, homes: ChiefPetHomes,
                picks: ChiefMascotPicks, uploads: ChiefAvatarUploads? = nil) {
        self.settings = settings
        self.homes = homes
        self.picks = picks
        self.uploads = uploads
        super.init()
        toggle.controlSize = .small
        toggle.target = self
        toggle.action = #selector(toggled)
        toggle.setAccessibilityIdentifier("cmux.home.chief.petEnabled")
        mascot.onPick = { [weak self] id in self?.pick(id) }
        guard uploads != nil else { return }
        mascot.onDrop = { [weak self] file in self?.upload(file) }
        uploadButton.target = self
        uploadButton.action = #selector(chooseUpload)
        uploadButton.bezelStyle = .push
        uploadButton.controlSize = .small
        uploadButton.setAccessibilityIdentifier("cmux.home.chief.petUpload")
        dropHint.font = Typography.caption
        dropHint.ink = .secondary
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
        addRow(ChiefPetMascot.pickerTitle, uploads == nil ? mascot : uploadStack())
        follow()
    }

    /// Shows the settings and `chief`'s character now and on each change, until the next `follow`.
    /// The default Chief's character is a setting and another's a pick, so what is observed depends
    /// on the Chief (`chief` itself is not observable): a new Chief starts a new watch.
    private func follow() {
        watch?.cancel()
        let chief = chief, settings = settings, picks = picks, uploads = uploads
        // task-owner: lives until the rows' Chief changes or the rows go (their Home view; deinit cancels it); event-driven (Observation)
        watch = Task { [weak self] in
            // Every change is shown (a trigger, never deduplicated): `show` compares with what it showed.
            for await shown in ObservationStream({ ObservationTrigger(Self.shown(settings(), picks: picks, uploads: uploads, chief: chief)) }) {
                guard let self, !Task.isCancelled else { return }
                if let shown = shown.value { show(shown) }
            }
        }
        if let shown = Self.shown(settings(), picks: picks, uploads: uploads, chief: chief) { show(shown) }
    }

    /// The grid with Upload Your Own… and the drop hint under it (`show` shows the one the affordance names).
    private func uploadStack() -> NSView {
        let stack = NSStackView(views: [mascot, uploadButton, dropHint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.space1
        return stack
    }

    // As HomeHostView's: not an isolated deinit; the watch ends with the rows (their Home view).
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated { watch?.cancel() }
    }

    /// The rows' state from the loaded settings and Chief `chief`'s pick. A managed
    /// `home.chiefPetMascot` locks the default Chief's character only.
    static func shown(_ settings: SettingsController?, picks: ChiefMascotPicks, uploads: ChiefAvatarUploads? = nil,
                      chief: String?) -> Shown? {
        guard let settings else { return nil }
        let snapshot = settings.snapshot
        return Shown(enabled: snapshot.homeChiefPetEnabled, mascot: picks.mascot(of: chief, in: snapshot),
                     enabledManaged: settings.managedKeys[HomeChiefPetSetting.configPath.joined(separator: ".")] != nil,
                     mascotManaged: picks.isDefault(chief)
                         && settings.managedKeys[HomeChiefPetSetting.mascotPath.joined(separator: ".")] != nil,
                     upload: uploads?.uploads[ChiefAvatarUploads.key(chief: chief ?? picks.defaultChief)],
                     affordance: ChiefPetTunables.uploadAffordance.value)
    }

    func show(_ shown: Shown) {
        toggle.state = shown.enabled ? .on : .off
        toggle.isEnabled = !shown.enabledManaged
        if uploads != nil {
            mascot.showUpload(shown.upload.map { (uploads?.image(at: $0.still), $0.still) }, tile: shown.affordance == .tile)
            uploadButton.isHidden = shown.affordance != .button || shown.upload != nil
            dropHint.isHidden = shown.affordance != .drop || shown.upload != nil
        }
        mascot.select(shown.isWorn ? ChiefPetMascotGrid.uploadID : shown.mascot, enabled: !shown.mascotManaged)
        uploadButton.isEnabled = !shown.mascotManaged
        if shown.face != shownMascot {
            shownMascot = shown.face
            onMascot?()
        }
    }

    /// Shows what the settings and the uploads hold now (after a pick that changed nothing).
    private func showCurrent() {
        if let shown = Self.shown(settings(), picks: picks, uploads: uploads, chief: chief) { show(shown) }
    }

    /// The key of the popover's Chief's upload.
    private var uploadKey: String { ChiefAvatarUploads.key(chief: chief ?? picks.defaultChief) }

    /// The popover's Chief's character picked now, which an upload is worn over.
    private var pickedMascot: String { picks.mascot(of: chief, in: settings()?.snapshot) }

    /// One click on a character: the default Chief's goes to `home.chiefPetMascot`, another Chief's
    /// to its own pick, and an upload stays, unworn. On the upload cell: "+" picks a file, an unworn
    /// upload is worn again, and the worn one opens Upload Your Own… and Remove Upload.
    private func pick(_ id: String) {
        if id == ChiefPetMascotGrid.uploadID, let uploads {
            if uploads.uploads[uploadKey] == nil {
                showCurrent()  // "+" is never checked: the open panel decides
                chooseUpload()
            } else if uploads.worn(of: uploadKey, over: pickedMascot) == nil {
                uploads.wear(uploadKey, over: pickedMascot)
            } else {
                uploadMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: mascot.uploadCell.bounds.maxY + Metrics.space1),
                                   in: mascot.uploadCell)
            }
            return
        }
        uploads?.wear(uploadKey, over: nil)  // even the character under it (another one displaces it anyway)
        guard !picks.isDefault(chief), let chief else { return write(HomeChiefPetSetting.mascotPath, .string(id)) }
        picks.remember(id, for: chief)
    }

    // MARK: Upload

    /// Replace and Remove, for the worn upload.
    private func uploadMenu() -> NSMenu {
        let menu = NSMenu()
        for (title, action) in [(ChiefAvatarUploads.chooseTitle, #selector(chooseUpload)), (ChiefAvatarUploads.removeTitle, #selector(removeUpload))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    /// Upload Your Own…: the file picker over the Home window (the popover closes when it takes the keys).
    /// The upload goes to the Chief the popover showed when the picker opened, whatever it shows after.
    @objc func chooseUpload() {
        let key = uploadKey, mascot = pickedMascot
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ChiefAvatarUploads.types
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        let use = { [weak self] (response: NSApplication.ModalResponse) in
            guard response == .OK, let file = panel.url else { return }
            self?.upload(file, for: key, over: mascot)
        }
        if let window = host?.window { panel.beginSheetModal(for: window, completionHandler: use) } else { use(panel.runModal()) }
    }

    @objc func removeUpload() {
        uploads?.remove(uploadKey)
    }

    /// Makes `file` the popover's Chief's upload and wears it; a refused one beeps and says why.
    func upload(_ file: URL) {
        upload(file, for: uploadKey, over: pickedMascot)
    }

    /// Makes `file` upload `key`'s, worn over `mascot`.
    private func upload(_ file: URL, for key: String, over mascot: String) {
        guard let uploads else { return }
        // task-owner: one upload (read, drawn down and written off the main actor); ends with it
        Task { [weak self] in
            do throws(ChiefAvatarUploads.Refusal) {
                try await uploads.store(from: file, for: key, over: mascot)
            } catch {
                NSSound.beep()
                self?.onRefusal?(error.message)
            }
        }
    }

    /// The picture Chief `chief` (nil: the default) wears where it has no avatar of its own: its worn
    /// upload's first frame, else its pet character's avatar picture.
    public static func characterPicture(of chief: String?, picks: ChiefMascotPicks, uploads: ChiefAvatarUploads?,
                                        in snapshot: CmuxConfigSnapshot?) -> URL? {
        wornUpload(of: chief, picks: picks, uploads: uploads, in: snapshot)?.still ?? avatarURL(of: picks.mascot(of: chief, in: snapshot))
    }

    /// Chief `chief`'s (nil: the default) upload while it is worn: over the character picked now, so
    /// a pick anywhere (the popover, Settings > Chiefs, the config file) puts the character back.
    public static func wornUpload(of chief: String?, picks: ChiefMascotPicks, uploads: ChiefAvatarUploads?,
                                  in snapshot: CmuxConfigSnapshot?) -> ChiefAvatarUploads.Upload? {
        uploads?.worn(of: ChiefAvatarUploads.key(chief: chief ?? picks.defaultChief), over: picks.mascot(of: chief, in: snapshot))
    }

    /// The avatar picture of the character `mascot` names (an unknown or nil id: the default, orb):
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

    /// The character's picture fit in a `side`-point square, its aspect kept, read from its PNG only
    /// when the square is drawn. These rows are built with Home, at launch, so a picture read when
    /// the grid was built put ten file reads (`NSImage.size`) on the main thread of every launch
    /// before the control socket was up; on a busy disk each waited seconds in getattrlist and the
    /// launch missed the nightly canary's 45 s wait for the socket. Nothing touches the file until
    /// the popover shows the grid.
    static func lazyThumbnail(of mascot: ChiefPetMascot, side: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            guard let picture = mascot.image else { return false }
            let natural = picture.size
            let scale = min(rect.width / max(natural.width, 1), rect.height / max(natural.height, 1))
            let drawn = NSSize(width: (natural.width * scale).rounded(), height: (natural.height * scale).rounded())
            picture.draw(in: NSRect(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2,
                                    width: drawn.width, height: drawn.height))
            return true
        }
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
                self?.showCurrent()
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
