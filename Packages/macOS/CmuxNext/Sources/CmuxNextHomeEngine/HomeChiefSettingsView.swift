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
/// - Agent: Harness, Model and Effort rows; "Default" names what it runs.
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
    /// UniiChat's one-line sign-in note under the Harness row (``ChiefBackend/hint``);
    /// hidden for every other harness.
    let harnessHint = ThemedLabel(wrappingLabelWithString: "")
    /// Why the engine could not be read or set, or a picture could not be used.
    let failure = ThemedLabel(wrappingLabelWithString: "")
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
    /// Renames the Chief conversation (the daemon's set-title op).
    public var onRename: (String) -> Void = { _ in }
    /// Where Choose Picture… and Use Default Picture write, and for which Chief: the daemon's
    /// registry for a Chief of this Mac (set by the header view); nil writes this panel's
    /// mux home's files (a cloud Chief).
    public var pictureStore: (avatars: HomeChiefAvatars, chief: String)?
    /// The Chief's avatar changed on disk (its picture): read it again.
    public var onAvatar: () -> Void = {}
    /// Show Memory: runs "Chief: Open Memory Inspector".
    public var onShowMemory: () -> Void = {}
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
    /// the user's own Claude login, Codex, and UniiChat, acpmux's built-in `unii`); the
    /// CodeRouter route (`claude-cr`) after Claude only when this Chief's acpmux has one
    /// configured. The subrouter pool (`claude-sr`) is never a default item; a current choice
    /// of it still shows (`fill`).
    nonisolated static func harnesses(routeConfigured: Bool) -> [String] {
        let official = ChiefBackend.official.map(\.id)
        guard routeConfigured else { return official }
        return [ChiefBackend.claude.id, "claude-cr"] + official.filter { $0 != ChiefBackend.claude.id }
    }

    /// The harness picker's items: each harness with the name the app shows for it.
    nonisolated static func harnessItems(routeConfigured: Bool) -> [(value: String, title: String)] {
        harnesses(routeConfigured: routeConfigured).map { ($0, ChiefBackend.title(for: $0)) }
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
        for (button, label) in [(harness, HomeEngineStrings.harness), (model, HomeEngineStrings.model), (effort, HomeEngineStrings.effort)] {
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
        let note = Self.footnote(HomeEngineStrings.nextTurn)
        note.preferredMaxLayoutWidth = Self.width - 2 * Self.inset
        addFullWidth(note)
        stack.setCustomSpacing(Metrics.space4, after: note)
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
        addFullWidth(diagnosticsRow())
        buildDiagnostics()
        addFullWidth(diagnostics)
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
        // A named Chief's panel keeps its own files (cx-327wl), never the default's.
        if let files = (source as? HomeChiefLocalEngine)?.files ?? (source as? HomeChiefRemoteEngine)?.files, files.muxHome != muxHome {
            muxHome = files.muxHome
            brain.stringValue = String(format: HomeEngineStrings.brainFormat, muxHome.path)
        }
        for view in localViews { view.isHidden = !source.isLocal }
        place.stringValue = hostPlace ?? source.place.map { String(format: HomeEngineStrings.runsOnServerFormat, $0) } ?? HomeEngineStrings.runsHere
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
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != shownName else { return }
        shownName = name
        onRename(name)
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

    /// Makes `source` the shown Chief's picture (nil: the default again) through
    /// ``pictureStore`` (the daemon's registry for a Chief of this Mac, else its files),
    /// then has the header (and this panel's avatar) read it; a picture that could not be
    /// used says so.
    func usePicture(_ source: URL?) {
        let store = pictureStore ?? (avatars: HomeChiefAvatars(muxHome: muxHome), chief: HomeChiefAvatars.defaultChief)
        // task-owner: one picture write (registry or files), then the header reads it
        Task { [weak self] in
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
            failure.stringValue = written ? "" : HomeEngineStrings.pictureUnreadable
            failure.isHidden = written
            onResize()
            if written { onAvatar() }
        }
    }

    @objc func showMemory() {
        onShowMemory()
    }

    @objc func openTraces() {
        NSWorkspace.shared.revealInBackground([HomeChiefFiles(muxHome: muxHome).traceDirectory])
    }

    // MARK: Engine

    /// Re-reads the engine and the last turns (a new message or a turn's
    /// end) off the main actor, then shows them, or why it could not.
    @discardableResult
    public func refresh() -> Task<Void, Never> {
        let source = source
        let home = muxHome
        // task-owner: one read off the main actor; ends when it is shown
        return Task { [weak self] in
            let result = await Task.detached { () async -> Result<HomeChiefSnapshot, HomeChiefEngineError> in
                do { return .success(try await source.read()) } catch let error as HomeChiefEngineError { return .failure(error) } catch { return .failure(.other(String(describing: error))) }
            }.value
            // A read of the Chief shown before (another conversation) is not shown.
            guard let self, self.source.isLocal == source.isLocal, self.source.place == source.place, muxHome == home else { return }
            switch result {
            case .success(let snapshot): show(snapshot)
            case .failure(let error): say(error, readable: false)
            }
        }
    }

    /// Sets (nil: clears) one engine field on the brain, then shows the result.
    @discardableResult
    public func pick(_ key: String, _ value: String?) -> Task<Void, Never> {
        let source = source
        let home = muxHome
        // task-owner: one write off the main actor; ends when its result is shown
        return Task { [weak self] in
            let result = await Task.detached { () async -> Result<HomeChiefSnapshot, HomeChiefEngineError> in
                do { return .success(try await source.set(key, value)) } catch let error as HomeChiefEngineError { return .failure(error) } catch { return .failure(.other(String(describing: error))) }
            }.value
            // A pick for the Chief shown before (another conversation) is not shown.
            guard let self, muxHome == home else { return }
            switch result {
            case .success(let snapshot):
                show(snapshot)
                onEngineChanged()
            case .failure(let error): say(error, readable: true)
            }
        }
    }

    /// Says `error`; the pickers stay usable only when the brain answered before.
    func say(_ error: HomeChiefEngineError, readable: Bool) {
        failure.stringValue = error.text
        failure.isHidden = false
        if !readable { for button in [harness, model, effort] { button.isEnabled = false } }
        onResize()
    }

    func show(_ snapshot: HomeChiefSnapshot) {
        failure.isHidden = true
        for button in [harness, model, effort] { button.isEnabled = true }
        let shown = HomeChiefEngineTitles(snapshot)
        fill(harness, shown.harnesses, current: snapshot.harness, defaultTitle: shown.defaultHarness, title: ChiefBackend.title(for:))
        showHarnessHint()
        fill(model, shown.models, current: snapshot.model, defaultTitle: shown.defaultModel)
        fill(effort, shown.efforts, current: snapshot.effort, defaultTitle: shown.defaultEffort)
        stats.stringValue = snapshot.turns.first.map(HomeEngineStrings.lastTurn) ?? HomeEngineStrings.noTurn
        // Which engine answered each recent reply (the trace's turn.end).
        replies.stringValue = snapshot.turns.isEmpty ? ""
            : HomeEngineStrings.answeredBy + "\n" + snapshot.turns.map(HomeEngineStrings.reply).joined(separator: "\n")
        replies.isHidden = snapshot.turns.isEmpty
        onResize()
    }

    /// `values` (value, title) after a "Default" item that names what it runs,
    /// and the current value kept even when it is not one of them (titled by `title`).
    func fill(_ button: NSPopUpButton, _ values: [(value: String, title: String)], current: String?, defaultTitle: String,
              title: (String) -> String = { $0 }) {
        button.removeAllItems()
        button.addItem(withTitle: defaultTitle)
        button.lastItem?.representedObject = nil
        var all = values
        if let current, !all.contains(where: { $0.value == current }) { all.append((current, title(current))) }
        for item in all {
            button.addItem(withTitle: item.title)
            button.lastItem?.representedObject = item.value
        }
        if let current, let index = all.firstIndex(where: { $0.value == current }) {
            button.selectItem(at: index + 1)
        } else {
            button.selectItem(at: 0)
        }
    }

    @objc func picked(_ sender: NSPopUpButton) {
        let key = sender === harness ? "harness" : sender === model ? "model" : "effort"
        if sender === harness { showHarnessHint() }
        pick(key, sender.selectedItem?.representedObject as? String)
    }

    /// The hint under the Harness row: only UniiChat's (sign in with `unii login` first), since
    /// the other engines' sign-in is the brain host's own (a cloud Chief's runs on its server).
    func showHarnessHint() {
        let unii = harness.selectedItem?.representedObject as? String == ChiefBackend.unii.id
        let hint = unii ? ChiefBackend.unii.hint : nil
        harnessHint.stringValue = hint ?? ""
        let changed = harnessHint.isHidden != (hint == nil)
        harnessHint.isHidden = hint == nil
        if changed { onResize() }
    }
}
