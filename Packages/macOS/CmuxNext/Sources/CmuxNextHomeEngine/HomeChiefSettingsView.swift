public import AppKit
import CmuxNextActions
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextHome
import Foundation
import CmuxNextCompat
import UniformTypeIdentifiers

/// The Chief's settings: the content of the popover the header's "Chief >"
/// name pill opens (`HomeChiefSettingsPopover`; Lawrence, 2026-10-05:
/// per-Chief configuration opens only from the pill). Leo 2026-10-19 ("kinda
/// yikes"): it was a right sidebar with no surface of its own that ran under
/// the header, a raw avatar text field, stacked pickers that all read
/// "Default", and the trace stats in the body. Now it is one settings card:
///
/// - Identity: the avatar, a menu to change it, and the name beside it.
/// - Agent: Harness, Model, Effort and (where the harness has a fast tier) Speed rows; "Default"
///   names what it runs. The Model menu groups by family (``HomeChiefModelMenu``) and Effort offers
///   only the levels the shown model takes.
/// - Reactions: whether a tapback wakes the Chief, and the classifier that decides (``HomeChiefReactionRows``).
/// - Appearance: rows other features add (`addAppearanceRow`), hidden while empty.
/// - Diagnostics: the last turns, where the brain runs, traces and memory,
///   behind a closed disclosure.
///
/// The pickers read and write the engine of the brain that answers this
/// Chief (`HomeChiefEngineSource`): this Mac's `<mux home>/optchat/engine.json`,
/// or a paired server's brain through `chief.engine.get` / `chief.engine.set`
/// for a cloud Chief. optchat-chief reads it at each turn start (engine.rs),
/// so a change applies from the next turn.
@MainActor
public final class HomeChiefSettingsView: NSView {
    /// The card's width; its height follows its content (`fittingSize`).
    public static let width: CGFloat = 320
    static let inset: CGFloat = 16
    static let avatarSize: CGFloat = 52
    static let pickerWidth: CGFloat = 188
    /// The shown Chief's mux home (its avatar, traces, the brain line); `use` moves it.
    var muxHome: URL
    let avatarButton = HomeChiefAvatarButton(size: avatarSize)
    let nameField = ThemedTextField(string: "")
    /// The title the field last showed or sent, so leaving it unchanged renames nothing.
    var shownName = ""
    /// Where the brain runs, under the name: this Mac or the paired server.
    let place = ThemedLabel(labelWithString: "")
    /// "Switch to …": the same Chief on its other host (Lawrence 2026-10-19 replaced the floating
    /// "Chief | Chief (Mac mini)" segmented control with this quiet link under where it runs).
    let hostSwitch = NSButton(title: "", target: nil, action: nil)
    /// The place line the app set (``setHost(place:switchTo:)``); nil keeps the engine's own line.
    var hostPlace: String?
    let harness = ThemedPopUpButton(frame: .zero, pullsDown: false)
    let model = ThemedPopUpButton(frame: .zero, pullsDown: false)
    let effort = ThemedPopUpButton(frame: .zero, pullsDown: false)
    /// Default or Fast; its row shows only where the turns' harness runs Fast (``HomeChiefEngineTitles/offersFast``).
    let speed = ThemedPopUpButton(frame: .zero, pullsDown: false)
    /// The models picked per harness, the Model menu's Recent section; the app passes its defaults.
    public var recents = HomeChiefModelRecents()
    /// UniiChat's one-line sign-in note under the Harness row (``ChiefBackend/hint``);
    /// hidden for every other harness.
    let harnessHint = ThemedLabel(wrappingLabelWithString: "")
    /// Why the engine could not be read or set, or a picture could not be used.
    let failure = ThemedLabel(wrappingLabelWithString: "")
    /// Whether a tapback can wake this Chief, and the classifier that decides (``HomeChiefReactionRows``).
    let reactionRows = HomeChiefReactionRows(width: HomeChiefSettingsView.width - 2 * HomeChiefSettingsView.inset)
    let appearanceHeader = ThemedLabel(labelWithString: HomeEngineStrings.appearanceSection)
    let appearanceRows = NSStackView()
    let diagnosticsToggle = NSButton()
    let diagnostics = NSStackView()
    let stats = ThemedLabel(wrappingLabelWithString: "")
    let replies = ThemedLabel(wrappingLabelWithString: "")
    /// The full mux home path and the brain's tools (this Mac's brain only).
    let brain = ThemedLabel(wrappingLabelWithString: "")
    let links = NSStackView()
    /// This Mac's brain only (its mux home, traces, memory): hidden for a
    /// Chief whose brain runs on a paired server.
    var localViews: [NSView] = []
    let stack = NSStackView()
    var source: any HomeChiefEngineSource
    /// The engine the pickers last showed (the brain's answer), which a refused pick shows again.
    var shownEngine: HomeChiefSnapshot?
    /// The note says why the person's own change did not take (a pick, a picture): it stays
    /// through refreshes until their next change or another Chief.
    var changeFailed = false
    /// The harness whose backend check is running (`pickHarness`); nil when none is.
    var checkingHarness: String?
    /// Runs harness `id`'s backend check on this Mac's acpmux (`_acpmux/harness/doctor`, one real
    /// hello turn); true when it passed. The app sets it; unset, every harness passes.
    public var checkHarness: @MainActor (String) async -> Bool = { _ in true }
    /// The ids of this Mac's acpmux harnesses (`_acpmux/harnesses`), which the Harness picker
    /// offers after the official engines for a Chief whose brain runs on this Mac. The app sets
    /// it; unset, the picker offers only the official engines.
    public var listHarnesses: @MainActor () async -> [String] = { [] }
    /// What ``listHarnesses`` last returned.
    var listedHarnesses: [String] = []
    /// Renames the Chief: the daemon's set-title op for a Chief of this Mac, the account's
    /// `chief.update` for a cloud Chief. Nil when the name was saved, else why it was not.
    public var onRename: @MainActor (String) async -> HomeChiefRenameFailure? = { _ in nil }
    /// Where Choose Picture… and Use Default Picture write, and for which Chief: the daemon's
    /// registry for a Chief of this Mac (set by the header view); nil writes this panel's
    /// mux home's files (a cloud Chief).
    public var pictureStore: (avatars: HomeChiefAvatars, chief: String)?
    /// The Chief's avatar changed on disk (its picture): read it again.
    public var onAvatar: () -> Void = {}
    /// Show Memory: runs "Chief: Open Memory Inspector".
    public var onShowMemory: () -> Void = {}
    /// All Chief Settings…: the app opens Settings > Chief (this card is the quick version).
    public var onAllSettings: () -> Void = {}
    /// "Switch to …" under where the Chief runs: the app moves the Chief tab to the other host.
    public var onSwitchHost: () -> Void = {}
    /// The brain took a pick (harness, model or effort): the Home list reads the Chiefs' engines again.
    public var onEngineChanged: () -> Void = {}
    /// The content's height changed (the disclosure, a failure note, new stats):
    /// the popover resizes to `fittingSize`.
    public var onResize: () -> Void = {}
    /// Choose Picture… runs its open panel over this window (the popover's
    /// parent), since the popover closes when the panel takes the keys.
    public var pictureWindow: () -> NSWindow? = { nil }

    /// The harness items the picker offers: the official engines (``ChiefBackend/official``:
    /// the user's own Claude login, Codex, Muse Code, and UniiChat, acpmux's built-in `unii`); the
    /// CodeRouter route (`claude-cr`) after Claude only when this Chief's acpmux has one
    /// configured; then every other harness `listed` by this Mac's acpmux
    /// (`_acpmux/harnesses`), in its order (Lawrence 2026-10-23: "chief can choose between
    /// literally all the acpmux stuff"). A current choice outside the list still shows (`fill`).
    nonisolated static func harnesses(routeConfigured: Bool, listed: [String] = []) -> [String] {
        let official = ChiefBackend.official.map(\.id)
        var offered = routeConfigured
            ? [ChiefBackend.claude.id, "claude-cr"] + official.filter { $0 != ChiefBackend.claude.id }
            : official
        var seen = Set(offered)
        for id in listed where !id.isEmpty && seen.insert(id).inserted { offered.append(id) }
        return offered
    }

    /// The harness picker's items: each harness with the name the app shows for it.
    nonisolated static func harnessItems(routeConfigured: Bool, listed: [String] = []) -> [(value: String, title: String)] {
        harnesses(routeConfigured: routeConfigured, listed: listed).map { ($0, ChiefBackend.title(for: $0)) }
    }

    public init(muxHome: URL, source: any HomeChiefEngineSource) {
        self.muxHome = muxHome
        self.source = source
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 0))
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityRole(.group)
        setAccessibilityLabel(HomeEngineStrings.title)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.space2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Self.inset),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.inset),
        ])
        addFullWidth(identityRow())
        stack.setCustomSpacing(Metrics.space4, after: stack.arrangedSubviews[0])
        failure.font = Typography.caption
        failure.ink = .danger
        failure.isHidden = true
        addFullWidth(failure)
        addFullWidth(Self.sectionHeader(HomeEngineStrings.agentSection))
        for (button, label) in [(harness, HomeEngineStrings.harness), (model, HomeEngineStrings.model), (effort, HomeEngineStrings.effort),
                                (speed, HomeEngineStrings.speed)] {
            button.target = self
            button.action = #selector(picked(_:))
            button.font = Typography.body
            button.setAccessibilityLabel(label)
            addFullWidth(Self.row(label, button))
            if button === harness {
                harnessHint.font = Typography.caption
                harnessHint.ink = .secondary
                harnessHint.isHidden = true
                harnessHint.setAccessibilityIdentifier("cmux.home.chief.harnessHint")
                harnessHint.preferredMaxLayoutWidth = Self.width - 2 * Self.inset
                addFullWidth(harnessHint)
            }
        }
        speed.superview?.isHidden = true
        let note = Self.footnote(HomeEngineStrings.nextTurn)
        note.preferredMaxLayoutWidth = Self.width - 2 * Self.inset
        addFullWidth(note)
        stack.setCustomSpacing(Metrics.space4, after: note)
        // Reactions: whether a tapback wakes this Chief, and the classifier that decides (a416).
        addFullWidth(Self.sectionHeader(HomeEngineStrings.reactionsSection))
        reactionRows.onPick = { [weak self] fields in self?.pick(fields) }
        reactionRows.onResize = { [weak self] in self?.onResize() }
        addFullWidth(reactionRows)
        stack.setCustomSpacing(Metrics.space4, after: reactionRows)
        // Appearance: rows other features add; the section shows once it has one.
        appearanceHeader.font = Typography.header
        appearanceHeader.ink = .secondary
        appearanceRows.orientation = .vertical
        appearanceRows.alignment = .leading
        appearanceRows.spacing = Metrics.space2
        addFullWidth(appearanceHeader)
        addFullWidth(appearanceRows)
        stack.setCustomSpacing(Metrics.space4, after: appearanceRows)
        appearanceHeader.isHidden = true
        appearanceRows.isHidden = true
        // The rest of the Chief's settings (the pet, the chat's look, every Chief) live in Settings.
        let allSettings = HomeChiefLinkButton(title: HomeEngineStrings.allChiefSettings, target: self, action: #selector(openAllSettings))
        allSettings.setAccessibilityIdentifier("cmux.home.chief.allSettings")
        stack.addArrangedSubview(allSettings)
        stack.setCustomSpacing(Metrics.space4, after: allSettings)
        addFullWidth(diagnosticsRow())
        buildDiagnostics()
        addFullWidth(diagnostics)
        showHarnessRow()
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    nonisolated public override var isFlipped: Bool { true }

    // MARK: Chief

    /// The brain this panel shows and sets: this Mac's (the default) or a
    /// paired server's (a cloud Chief), then a read of it.
    @discardableResult
    public func use(_ source: any HomeChiefEngineSource) -> Task<Void, Never> {
        self.source = source
        shownEngine = nil
        changeFailed = false
        checkingHarness = nil
        // A named Chief's panel keeps its own files (cx-327wl), never the default's.
        let files = (source as? HomeChiefLocalEngine)?.files ?? (source as? HomeChiefRemoteEngine)?.files ?? (source as? HomeChiefHostedEngine)?.files
        if let files, files.muxHome != muxHome {
            muxHome = files.muxHome
            brain.stringValue = String(format: HomeEngineStrings.brainFormat, muxHome.path)
        }
        for view in localViews { view.isHidden = !source.isLocal }
        showHarnessRow()
        let own = source is HomeChiefHostedEngine ? HomeEngineStrings.runsInCloud : HomeEngineStrings.runsHere
        place.stringValue = hostPlace ?? source.place.map { String(format: HomeEngineStrings.runsOnServerFormat, $0) } ?? own
        return refresh()
    }

    /// Where this Chief runs and the other host it can switch to.
    ///
    /// - Parameters:
    ///   - place: The line under the name ("Runs in the cloud"); nil keeps the engine's own line.
    ///   - switchTo: The other host's label ("cmux20", "Cloud"); nil hides the switch.
    public func setHost(place: String?, switchTo: String?) {
        hostPlace = place
        if let place { self.place.stringValue = place }
        hostSwitch.title = switchTo.map { String(format: HomeEngineStrings.switchHostFormat, $0) } ?? ""
        hostSwitch.setAccessibilityLabel(hostSwitch.title)
        let hidden = switchTo == nil
        guard hostSwitch.isHidden != hidden else { return }
        hostSwitch.isHidden = hidden
        onResize()
    }

    /// The Harness row only for a brain whose harness the owner picks (not a hosted cloud Chief's).
    func showHarnessRow() {
        let hidden = !source.choosesHarness
        guard let row = harness.superview, row.isHidden != hidden else { return }
        row.isHidden = hidden
        if hidden { harnessHint.isHidden = true }
        onResize()
    }

    @objc func switchHost() {
        onSwitchHost()
    }

    /// The conversation's title, shown in the name field.
    public func setName(_ name: String) {
        shownName = name
        if nameField.currentEditor() == nil { nameField.stringValue = name }
    }

    /// The avatar the header shows: its picture, else its text (one or two characters).
    public func setAvatar(picture: NSImage?, text: String?) {
        avatarButton.show(picture: picture, text: text)
    }

    /// Ends an edit in progress (the name), so a close keeps it.
    public func commitEditing() {
        guard nameField.currentEditor() != nil else { return }
        window?.makeFirstResponder(nil)
    }

    /// Return, or the end of an edit: a new, non-empty name renames the Chief.
    @objc func renamed() {
        commitName()
    }

    /// Renames the Chief to the field's new, non-empty name; nil when the name is no change. A
    /// rename the daemon refuses (or with no daemon to send it to) shows the kept name again and
    /// says so, unless a newer name came since. The Home reads the title again on every
    /// transcript or typing change (`setName`), so the kept name arriving meanwhile is no newer name.
    @discardableResult
    func commitName() -> Task<Void, Never>? {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        // A blank name renames nothing, so the field shows the name the Chief keeps; a kept
        // name shows as it is saved, without the spaces around it.
        nameField.stringValue = name.isEmpty ? shownName : name
        guard !name.isEmpty, name != shownName else { return nil }
        let kept = shownName
        shownName = name
        // task-owner: one rename; ends with the owner's answer
        return Task { [weak self] in
            guard let self else { return }
            let failure = await onRename(name)
            guard shownName == name || shownName == kept else { return }
            guard let failure else {
                // A saved name: an earlier rename's note no longer applies.
                if changeFailed, !self.failure.isHidden { hideNote() }
                return
            }
            shownName = kept
            // Still in the field after Return: it shows the kept name too, unless the person typed on.
            if nameField.currentEditor() == nil || nameField.stringValue == name { nameField.stringValue = kept }
            note(HomeEngineStrings.renameFailed(failure), kept: true)
        }
    }

    // MARK: Picture

    /// The avatar's menu: a picture of your own, or the bundled one again (backgrounds plan phase 4).
    @objc func showPictureMenu() {
        let menu = NSMenu()
        let choose = NSMenuItem(title: HomeEngineStrings.choosePicture, action: #selector(choosePicture), keyEquivalent: "")
        let reset = NSMenuItem(title: HomeEngineStrings.useDefaultPicture, action: #selector(useDefaultPicture), keyEquivalent: "")
        for item in [choose, reset] {
            item.target = self
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: CmuxPopoverAnchor.menuPoint(in: avatarButton), in: avatarButton)
    }

    @objc func choosePicture() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = HomeChiefFiles.pictureTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        let use = { [weak self] (response: NSApplication.ModalResponse) in
            guard response == .OK, let url = panel.url else { return }
            self?.usePicture(url)
        }
        if let window = pictureWindow() ?? window { panel.beginSheetModal(for: window, completionHandler: use) } else { use(panel.runModal()) }
    }

    @objc func useDefaultPicture() {
        usePicture(nil)
    }

    /// Says `text` on the card's note line (another part's refused change, such as an upload),
    /// kept until the person's next change, as a refused picture's note is.
    public func showNote(_ text: String) {
        note(text, kept: true)
    }

    /// Makes `source` the shown Chief's picture (nil: the default again) through
    /// ``pictureStore`` (the daemon's registry for a Chief of this Mac, else its files),
    /// then has the header (and this panel's avatar) read it; a picture that could not be
    /// used says so, with a beep, since the open panel closed the card (the note waits for its
    /// next open).
    @discardableResult
    func usePicture(_ source: URL?) -> Task<Void, Never> {
        let store = pictureStore ?? (avatars: HomeChiefAvatars(muxHome: muxHome), chief: HomeChiefAvatars.defaultChief)
        changeFailed = false
        // task-owner: one picture write (registry or files), then the header reads it
        return Task { [weak self] in
            let written: Bool
            do {
                if let source { try await store.avatars.setPicture(from: source, chief: store.chief) } else {
                    try await store.avatars.clearPicture(chief: store.chief)
                }
                written = true
            } catch {
                written = false
            }
            guard let self else { return }
            if written {
                hideNote()
                onAvatar()
            } else {
                NSSound.beep()
                note(HomeEngineStrings.pictureUnreadable, kept: true)
            }
        }
    }

    @objc func showMemory() {
        onShowMemory()
    }

    @objc func openAllSettings() {
        onAllSettings()
    }

    @objc func openTraces() {
        NSWorkspace.shared.revealInBackground([HomeChiefFiles(muxHome: muxHome).traceDirectory])
    }
}
