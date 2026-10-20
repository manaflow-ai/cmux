public import AppKit
import CmuxNextActions
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextHome
import Foundation
import CmuxNextCompat
import UniformTypeIdentifiers

/// The Chief's settings, a right sidebar inside the Home page that the
/// header's "Chief >" name pill toggles (Lawrence, 2026-10-05: per-Chief
/// configuration opens only from the pill). One per Chief: the pickers read
/// and write the engine of the brain that answers it (`HomeChiefEngineSource`):
/// this Mac's `<mux home>/optchat/engine.json`, or a paired server's brain
/// through `chief.engine.get` / `chief.engine.set` for a cloud Chief.
/// optchat-chief reads it at each turn start (engine.rs), so a change
/// applies from the next turn. It also shows the last turns' engines and
/// stats, where the brain runs, and (this Mac's brain only) its traces.
@MainActor
public final class HomeChiefSidebar: NSView {
    public static let width: CGFloat = 280
    /// The shown Chief's mux home (its avatar, traces, the brain line); `use` moves it.
    private var muxHome: URL
    private let brain = ThemedLabel(wrappingLabelWithString: "")
    private let harness = ThemedPopUpButton(frame: .zero, pullsDown: false)
    private let model = ThemedPopUpButton(frame: .zero, pullsDown: false)
    private let effort = ThemedPopUpButton(frame: .zero, pullsDown: false)
    private let stats = ThemedLabel(wrappingLabelWithString: "")
    private let replies = ThemedLabel(wrappingLabelWithString: "")
    private let nameField = ThemedTextField(string: "")
    private let avatarField = ThemedTextField(string: "")
    /// The avatar text the field last showed, so an unchanged commit writes nothing.
    private var shownAvatar = ""
    private let stack = NSStackView()
    /// This Mac's brain only (its mux home, traces, memory): hidden for a
    /// Chief whose brain runs on a paired server.
    private var localViews: [NSView] = []
    /// Where a paired server's brain runs.
    private let place = ThemedLabel(wrappingLabelWithString: "")
    /// Why the engine could not be read or set.
    private let failure = ThemedLabel(wrappingLabelWithString: "")
    /// UniiChat's one-line sign-in note under the harness picker (``ChiefBackend/hint``);
    /// hidden for every other harness.
    private let harnessHint = ThemedLabel(wrappingLabelWithString: "")
    private var source: any HomeChiefEngineSource
    /// Renames the Chief conversation (the daemon's set-title op).
    public var onRename: (String) -> Void = { _ in }
    /// The Chief's avatar changed on disk (its text or picture): read it again.
    public var onAvatar: () -> Void = {}
    /// Show Memory: runs "Chief: Open Memory Inspector".
    public var onShowMemory: () -> Void = {}
    /// The brain took a pick (harness, model or effort): the Home list reads the Chiefs' engines again.
    public var onEngineChanged: () -> Void = {}

    /// The harness items the picker offers: the official engines (``ChiefBackend/official``:
    /// the user's own Claude login, Codex, and UniiChat, acpmux's built-in `unii`); the
    /// CodeRouter route (`claude-cr`) after Claude only when this Chief's acpmux has one
    /// configured. The subrouter pool (`claude-sr`) is never a default item; a current choice
    /// of it still shows (`fill`).
    static func harnesses(routeConfigured: Bool) -> [String] {
        let official = ChiefBackend.official.map(\.id)
        guard routeConfigured else { return official }
        return [ChiefBackend.claude.id, "claude-cr"] + official.filter { $0 != ChiefBackend.claude.id }
    }

    /// The harness picker's items: each harness with the name the app shows for it.
    static func harnessItems(routeConfigured: Bool) -> [(value: String, title: String)] {
        harnesses(routeConfigured: routeConfigured).map { ($0, ChiefBackend.title(for: $0)) }
    }

    public init(muxHome: URL, source: any HomeChiefEngineSource) {
        self.muxHome = muxHome
        self.source = source
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityRole(.group)
        setAccessibilityLabel(HomeEngineStrings.title)
        let title = ThemedLabel(labelWithString: HomeEngineStrings.title)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.addArrangedSubview(title)
        // Name and avatar of this Chief.
        for (field, label, action) in [(nameField, HomeEngineStrings.name, #selector(renamed)),
                                       (avatarField, HomeEngineStrings.avatar, #selector(avatarChanged))] {
            let caption = ThemedLabel(labelWithString: label)
            caption.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            caption.ink = .secondary
            field.target = self
            field.action = action
            field.setAccessibilityLabel(label)
            field.placeholderString = label
            field.font = Typography.body
            let box = ThemedFieldBox(field: field, height: Metrics.controlHeight)
            stack.addArrangedSubview(caption)
            stack.addArrangedSubview(box)
            box.widthAnchor.constraint(equalToConstant: Self.width - 32).isActive = true
        }
        // A picture of your own, or the bundled one again (backgrounds plan phase 4).
        let pictures = NSStackView(views: [
            ThemedBezelButton(title: HomeEngineStrings.choosePicture, target: self, action: #selector(choosePicture)),
            ThemedBezelButton(title: HomeEngineStrings.useDefaultPicture, target: self, action: #selector(useDefaultPicture)),
        ])
        pictures.spacing = 8
        stack.addArrangedSubview(pictures)
        for (button, label) in [(harness, HomeEngineStrings.harness), (model, HomeEngineStrings.model), (effort, HomeEngineStrings.effort)] {
            button.target = self
            button.action = #selector(picked(_:))
            button.setAccessibilityLabel(label)
            let caption = ThemedLabel(labelWithString: label)
            caption.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            caption.ink = .secondary
            stack.addArrangedSubview(caption)
            stack.addArrangedSubview(button)
            button.widthAnchor.constraint(equalToConstant: Self.width - 32).isActive = true
            if button === harness {
                harnessHint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
                harnessHint.ink = .secondary
                harnessHint.isHidden = true
                harnessHint.setAccessibilityIdentifier("cmux.home.chief.harnessHint")
                stack.addArrangedSubview(harnessHint)
            }
        }
        let note = ThemedLabel(wrappingLabelWithString: HomeEngineStrings.nextTurn)
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.ink = .secondary
        stack.addArrangedSubview(note)
        stats.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        stats.ink = .secondary
        stack.addArrangedSubview(stats)
        replies.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        replies.ink = .secondary
        stack.addArrangedSubview(replies)
        brain.stringValue = String(format: HomeEngineStrings.brainFormat, muxHome.path)
        brain.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        brain.ink = .secondary
        stack.addArrangedSubview(brain)
        let traces = ThemedBezelButton(title: HomeEngineStrings.openTraces, target: self, action: #selector(openTraces))
        traces.bezelStyle = .push
        stack.addArrangedSubview(traces)
        // The memory inspector (DEV and nightly, like its palette action).
        if DevTools.isEnabled {
            let memory = ThemedBezelButton(title: HomeEngineStrings.showMemory, target: self, action: #selector(showMemory))
            memory.bezelStyle = .push
            stack.addArrangedSubview(memory)
            localViews.append(memory)
        }
        localViews += [brain, traces]
        place.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        place.ink = .secondary
        place.isHidden = true
        stack.insertArrangedSubview(place, at: stack.arrangedSubviews.firstIndex(of: brain) ?? 0)
        failure.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        failure.ink = .danger
        failure.isHidden = true
        stack.insertArrangedSubview(failure, at: stack.arrangedSubviews.firstIndex(of: note) ?? 0)
        for view in [note, stats, replies, brain, place, failure, harnessHint] {
            view.preferredMaxLayoutWidth = Self.width - 32
        }
        addSubview(stack)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    nonisolated public override var isFlipped: Bool { true }

    /// The theme's sidebar step (a panel apart from the Home content), or the user's sidebar
    /// background (`appearance.surfaces`), like the window's left sidebar; re-resolved on a theme change.
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyThemeFill()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyThemeFill()
    }

    private func applyThemeFill() {
        layer?.backgroundColor = performWithTheme { Palette.fill(for: .sidebar, default: Palette.sidebarStep).cgColor }
    }

    public override func layout() {
        super.layout()
        stack.frame = CGRect(x: 0, y: 0, width: Self.width, height: bounds.height)
    }

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
        place.isHidden = source.isLocal
        place.stringValue = source.place.map { String(format: HomeEngineStrings.runsOnServerFormat, $0) } ?? ""
        return refresh()
    }


    /// The conversation's title, shown in the name field.
    public func setName(_ name: String) {
        if nameField.currentEditor() == nil { nameField.stringValue = name }
    }

    @objc private func renamed() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { onRename(name) }
    }

    /// The avatar text (at most 2 characters, an emoji counts as one), kept
    /// in `<mux home>/optchat/profile.json` beside this Chief's settings.
    @objc private func avatarChanged() {
        let text = String(avatarField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2))
        avatarField.stringValue = text
        // Return on an unchanged field keeps the avatar (a picture shows as "").
        guard text != shownAvatar else { return }
        shownAvatar = text
        let files = HomeChiefFiles(muxHome: muxHome)
        // task-owner: one file write off the main actor, then the header reads it
        Task { [weak self] in
            await Task.detached { files.writeAvatar(text) }.value
            self?.onAvatar()
        }
    }

    @objc private func choosePicture() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = HomeChiefFiles.pictureTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        let use = { [weak self] (response: NSApplication.ModalResponse) in
            guard response == .OK, let url = panel.url else { return }
            self?.usePicture { try $0.writePicture(from: url) }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: use) } else { use(panel.runModal()) }
    }

    @objc private func useDefaultPicture() {
        usePicture { $0.clearPicture() }
    }

    /// Writes the picture off the main actor, then clears the text field (a picture shows no
    /// text) and has the header read it; a picture that could not be used says so.
    private func usePicture(_ write: @escaping @Sendable (HomeChiefFiles) throws -> Void) {
        let files = HomeChiefFiles(muxHome: muxHome)
        // task-owner: one file write off the main actor, then the header reads it
        Task { [weak self] in
            let written = await Task.detached { (try? write(files)) != nil }.value
            guard let self else { return }
            failure.stringValue = written ? "" : HomeEngineStrings.pictureUnreadable
            failure.isHidden = written
            guard written else { return }
            avatarField.stringValue = ""
            shownAvatar = ""
            onAvatar()
        }
    }

    @objc private func showMemory() {
        onShowMemory()
    }

    @objc private func openTraces() {
        NSWorkspace.shared.revealInBackground([HomeChiefFiles(muxHome: muxHome).traceDirectory])
    }

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
    private func say(_ error: HomeChiefEngineError, readable: Bool) {
        failure.stringValue = error.text
        failure.isHidden = false
        if !readable { for button in [harness, model, effort] { button.isEnabled = false } }
    }

    private func show(_ snapshot: HomeChiefSnapshot) {
        failure.isHidden = true
        for button in [harness, model, effort] { button.isEnabled = true }
        fill(harness, Self.harnessItems(routeConfigured: snapshot.routeConfigured), current: snapshot.harness, title: ChiefBackend.title(for:))
        showHarnessHint()
        // The models acpmux offers for the engine's harness and the efforts the brain takes
        // (cx-miuo); acpmux's own "default" is the picker's first item.
        fill(model, snapshot.models.filter { $0.id != "default" }.map { ($0.id, $0.name) }, current: snapshot.model)
        fill(effort, snapshot.efforts.map { ($0, $0) }, current: snapshot.effort)
        // A picture's file name is not avatar text; the field stays empty for it.
        if avatarField.currentEditor() == nil {
            shownAvatar = snapshot.avatar.flatMap { HomeChiefFiles.namesPicture($0) ? nil : $0 } ?? ""
            avatarField.stringValue = shownAvatar
        }
        stats.stringValue = snapshot.turns.first.map(HomeEngineStrings.lastTurn) ?? HomeEngineStrings.noTurn
        // Which engine answered each recent reply (the trace's turn.end).
        replies.stringValue = snapshot.turns.isEmpty ? ""
            : HomeEngineStrings.answeredBy + "\n" + snapshot.turns.map(HomeEngineStrings.reply).joined(separator: "\n")
    }

    /// `values` (value, title) with a "default" first and the current value
    /// kept even when it is not one of them (titled by `title`).
    private func fill(_ button: NSPopUpButton, _ values: [(value: String, title: String)], current: String?,
                      title: (String) -> String = { $0 }) {
        button.removeAllItems()
        button.addItem(withTitle: HomeEngineStrings.defaultValue)
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

    @objc private func picked(_ sender: NSPopUpButton) {
        let key = sender === harness ? "harness" : sender === model ? "model" : "effort"
        if sender === harness { showHarnessHint() }
        pick(key, sender.selectedItem?.representedObject as? String)
    }

    /// The hint under the harness picker: only UniiChat's (sign in with `unii login` first), since
    /// the other engines' sign-in is the brain host's own (a cloud Chief's runs on its server).
    private func showHarnessHint() {
        let unii = harness.selectedItem?.representedObject as? String == ChiefBackend.unii.id
        let hint = unii ? ChiefBackend.unii.hint : nil
        harnessHint.stringValue = hint ?? ""
        harnessHint.isHidden = hint == nil
    }
}
