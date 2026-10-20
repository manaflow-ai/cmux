public import AppKit
import CmuxNextActions
import CmuxNextDaemon
import CmuxNextDesign
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
    private var muxHome: URL
    private let avatarButton = HomeChiefAvatarButton(size: avatarSize)
    private let nameField = ThemedTextField(string: "")
    /// Where the brain runs, under the name: this Mac or the paired server.
    private let place = ThemedLabel(labelWithString: "")
    private let harness = ThemedPopUpButton(frame: .zero, pullsDown: false)
    private let model = ThemedPopUpButton(frame: .zero, pullsDown: false)
    private let effort = ThemedPopUpButton(frame: .zero, pullsDown: false)
    /// Why the engine could not be read or set, or a picture could not be used.
    private let failure = ThemedLabel(wrappingLabelWithString: "")
    private let appearanceHeader = ThemedLabel(labelWithString: HomeEngineStrings.appearanceSection)
    private let appearanceRows = NSStackView()
    private let diagnosticsToggle = NSButton()
    private let diagnostics = NSStackView()
    private let stats = ThemedLabel(wrappingLabelWithString: "")
    private let replies = ThemedLabel(wrappingLabelWithString: "")
    /// The full mux home path and the brain's tools (this Mac's brain only).
    private let brain = ThemedLabel(wrappingLabelWithString: "")
    private let links = NSStackView()
    /// This Mac's brain only (its mux home, traces, memory): hidden for a
    /// Chief whose brain runs on a paired server.
    private var localViews: [NSView] = []
    private let stack = NSStackView()
    private var source: any HomeChiefEngineSource
    /// Renames the Chief conversation (the daemon's set-title op).
    public var onRename: (String) -> Void = { _ in }
    /// The Chief's avatar changed on disk (its picture): read it again.
    public var onAvatar: () -> Void = {}
    /// Show Memory: runs "Chief: Open Memory Inspector".
    public var onShowMemory: () -> Void = {}
    /// The content's height changed (the disclosure, a failure note, new stats):
    /// the popover resizes to `fittingSize`.
    public var onResize: () -> Void = {}
    /// Choose Picture… runs its open panel over this window (the popover's
    /// parent), since the popover closes when the panel takes the keys.
    public var pictureWindow: () -> NSWindow? = { nil }

    /// The harness items the picker offers: the user's own Claude login and
    /// Codex; the CodeRouter route (`claude-cr`) only when this Chief's
    /// acpmux has one configured. The subrouter pool (`claude-sr`) is never a
    /// default item; a current choice of it still shows (`fill`).
    static func harnesses(routeConfigured: Bool) -> [String] {
        routeConfigured ? ["claude", "claude-cr", "codex"] : ["claude", "codex"]
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
        }
        let note = Self.footnote(HomeEngineStrings.nextTurn)
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

    // MARK: Layout

    private func addFullWidth(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    /// The avatar (a menu changes it) with the name and where the brain runs beside it.
    private func identityRow() -> NSView {
        avatarButton.target = self
        avatarButton.action = #selector(showPictureMenu)
        avatarButton.setAccessibilityLabel(HomeEngineStrings.changePicture)
        avatarButton.toolTip = HomeEngineStrings.changePicture
        nameField.target = self
        nameField.action = #selector(renamed)
        nameField.setAccessibilityLabel(HomeEngineStrings.name)
        nameField.placeholderString = HomeEngineStrings.name
        nameField.font = Typography.body
        let box = ThemedFieldBox(field: nameField, height: Metrics.controlHeight)
        place.font = Typography.caption
        place.ink = .secondary
        place.lineBreakMode = .byTruncatingTail
        place.stringValue = HomeEngineStrings.runsHere
        let text = NSStackView(views: [box, place])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = Metrics.space1
        text.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true
        place.widthAnchor.constraint(lessThanOrEqualTo: text.widthAnchor).isActive = true
        let row = NSStackView(views: [avatarButton, text])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Metrics.space3
        return row
    }

    /// A section's title: secondary ink, the header weight.
    static func sectionHeader(_ title: String) -> NSView {
        let label = ThemedLabel(labelWithString: title)
        label.font = Typography.header
        label.ink = .secondary
        return label
    }

    /// One settings row: the label at the leading edge, the control at the trailing edge.
    static func row(_ title: String, _ control: NSView) -> NSView {
        let label = ThemedLabel(labelWithString: title)
        label.font = Typography.body
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        control.translatesAutoresizingMaskIntoConstraints = false
        if control is NSPopUpButton {
            control.widthAnchor.constraint(equalToConstant: pickerWidth).isActive = true
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let row = NSStackView(views: [label, spacer, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Metrics.space2
        return row
    }

    static func footnote(_ text: String) -> ThemedLabel {
        let label = ThemedLabel(wrappingLabelWithString: text)
        label.font = Typography.caption
        label.ink = .tertiary
        return label
    }

    /// Adds a row to the Appearance section (the Chief's bubble style, its pet):
    /// a title at the leading edge and `control` at the trailing edge.
    public func addAppearanceRow(_ title: String, control: NSView) {
        let row = Self.row(title, control)
        row.translatesAutoresizingMaskIntoConstraints = false
        appearanceRows.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: appearanceRows.widthAnchor).isActive = true
        appearanceHeader.isHidden = false
        appearanceRows.isHidden = false
        onResize()
    }

    /// The closed disclosure over the diagnostics: a triangle and its title, one click target.
    private func diagnosticsRow() -> NSView {
        diagnosticsToggle.setButtonType(.pushOnPushOff)
        diagnosticsToggle.bezelStyle = .disclosure
        diagnosticsToggle.title = ""
        diagnosticsToggle.state = .off
        diagnosticsToggle.target = self
        diagnosticsToggle.action = #selector(toggleDiagnostics)
        diagnosticsToggle.setAccessibilityLabel(HomeEngineStrings.diagnostics)
        let title = HomeChiefLinkButton(title: HomeEngineStrings.diagnostics, target: self, action: #selector(clickDiagnosticsTitle))
        title.ink = .secondary
        title.textFont = Typography.header
        let row = NSStackView(views: [diagnosticsToggle, title])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Metrics.space1
        return row
    }

    private func buildDiagnostics() {
        diagnostics.orientation = .vertical
        diagnostics.alignment = .leading
        diagnostics.spacing = Metrics.space2
        diagnostics.isHidden = true
        for label in [stats, replies, brain] {
            label.font = Typography.caption
            label.ink = .secondary
            label.preferredMaxLayoutWidth = Self.width - 2 * Self.inset
            label.translatesAutoresizingMaskIntoConstraints = false
            diagnostics.addArrangedSubview(label)
            label.widthAnchor.constraint(equalTo: diagnostics.widthAnchor).isActive = true
        }
        failure.preferredMaxLayoutWidth = Self.width - 2 * Self.inset
        brain.stringValue = String(format: HomeEngineStrings.brainFormat, muxHome.path)
        // Show Traces and, in DEV and nightly like its palette action, Show Memory: plain links.
        let traces = HomeChiefLinkButton(title: HomeEngineStrings.openTraces, target: self, action: #selector(openTraces))
        links.addArrangedSubview(traces)
        if DevTools.isEnabled {
            links.addArrangedSubview(HomeChiefLinkButton(title: HomeEngineStrings.showMemory, target: self, action: #selector(showMemory)))
        }
        links.orientation = .horizontal
        links.spacing = Metrics.space4
        diagnostics.addArrangedSubview(links)
        localViews = [brain, links]
    }

    @objc private func clickDiagnosticsTitle() {
        diagnosticsToggle.state = diagnosticsToggle.state == .on ? .off : .on
        toggleDiagnostics()
    }

    @objc private func toggleDiagnostics() {
        diagnostics.isHidden = diagnosticsToggle.state != .on
        onResize()
    }

    /// Whether the diagnostics show (tests).
    var showsDiagnostics: Bool { !diagnostics.isHidden }

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
        place.stringValue = source.place.map { String(format: HomeEngineStrings.runsOnServerFormat, $0) } ?? HomeEngineStrings.runsHere
        return refresh()
    }

    /// The conversation's title, shown in the name field.
    public func setName(_ name: String) {
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

    @objc private func renamed() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { onRename(name) }
    }

    // MARK: Picture

    /// The avatar's menu: a picture of your own, or the bundled one again (backgrounds plan phase 4).
    @objc private func showPictureMenu() {
        let menu = NSMenu()
        let choose = NSMenuItem(title: HomeEngineStrings.choosePicture, action: #selector(choosePicture), keyEquivalent: "")
        let reset = NSMenuItem(title: HomeEngineStrings.useDefaultPicture, action: #selector(useDefaultPicture), keyEquivalent: "")
        for item in [choose, reset] {
            item.target = self
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: CmuxPopoverAnchor.menuPoint(in: avatarButton), in: avatarButton)
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
        if let window = pictureWindow() ?? window { panel.beginSheetModal(for: window, completionHandler: use) } else { use(panel.runModal()) }
    }

    @objc private func useDefaultPicture() {
        usePicture { $0.clearPicture() }
    }

    /// Writes the picture off the main actor, then has the header (and this
    /// panel's avatar) read it; a picture that could not be used says so.
    private func usePicture(_ write: @escaping @Sendable (HomeChiefFiles) throws -> Void) {
        let files = HomeChiefFiles(muxHome: muxHome)
        // task-owner: one file write off the main actor, then the header reads it
        Task { [weak self] in
            let written = await Task.detached { (try? write(files)) != nil }.value
            guard let self else { return }
            failure.stringValue = written ? "" : HomeEngineStrings.pictureUnreadable
            failure.isHidden = written
            onResize()
            if written { onAvatar() }
        }
    }

    @objc private func showMemory() {
        onShowMemory()
    }

    @objc private func openTraces() {
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
            case .success(let snapshot): show(snapshot)
            case .failure(let error): say(error, readable: true)
            }
        }
    }

    /// Says `error`; the pickers stay usable only when the brain answered before.
    private func say(_ error: HomeChiefEngineError, readable: Bool) {
        failure.stringValue = error.text
        failure.isHidden = false
        if !readable { for button in [harness, model, effort] { button.isEnabled = false } }
        onResize()
    }

    private func show(_ snapshot: HomeChiefSnapshot) {
        failure.isHidden = true
        for button in [harness, model, effort] { button.isEnabled = true }
        let shown = HomeChiefEngineTitles(snapshot)
        fill(harness, shown.harnesses, current: snapshot.harness, defaultTitle: shown.defaultHarness)
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
    /// and the current value kept even when it is not one of them.
    private func fill(_ button: NSPopUpButton, _ values: [(value: String, title: String)], current: String?, defaultTitle: String) {
        button.removeAllItems()
        button.addItem(withTitle: defaultTitle)
        button.lastItem?.representedObject = nil
        var all = values
        if let current, !all.contains(where: { $0.value == current }) { all.append((current, current)) }
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
        pick(key, sender.selectedItem?.representedObject as? String)
    }
}

/// The pickers' items and their "Default" titles for one snapshot: "Default"
/// alone says nothing, so it names what the brain runs without a choice
/// ("Default (claude)", "Default (Opus 5.5)"), from the brain's report.
nonisolated struct HomeChiefEngineTitles {
    var harnesses: [(value: String, title: String)]
    var models: [(value: String, title: String)]
    var efforts: [(value: String, title: String)]
    var defaultHarness: String
    var defaultModel: String
    var defaultEffort: String

    init(_ snapshot: HomeChiefSnapshot) {
        harnesses = HomeChiefSettingsView.harnesses(routeConfigured: snapshot.routeConfigured).map { ($0, $0) }
        // The models acpmux offers for the engine's harness and the efforts the brain takes
        // (cx-miuo); acpmux's own "default" is the picker's first item.
        models = snapshot.models.filter { $0.id != "default" }.map { ($0.id, $0.name) }
        efforts = snapshot.efforts.map { ($0, $0) }
        let engine = snapshot.effective
        defaultHarness = Self.titled(engine?.harness)
        // A model id the offer names shows by its name.
        let modelName = engine?.model.flatMap { id in snapshot.models.first { $0.id == id }?.name ?? id }
        defaultModel = Self.titled(modelName)
        defaultEffort = Self.titled(engine?.effort)
    }

    /// "Default (value)", or "Default" when the brain did not say (or says "default").
    static func titled(_ value: String?) -> String {
        guard let value, !value.isEmpty, value != "default" else { return HomeEngineStrings.defaultValue }
        return String(format: HomeEngineStrings.defaultNamedFormat, value)
    }
}

/// The Chief's avatar in the settings card: its picture (or text) in a disc;
/// a click opens the menu that changes it.
@MainActor
final class HomeChiefAvatarButton: NSButton {
    private let size: CGFloat

    init(size: CGFloat) {
        self.size = size
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        isBordered = false
        bezelStyle = .regularSquare
        title = ""
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyUpOrDown
        wantsLayer = true
        layer?.cornerRadius = size / 2
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: size), heightAnchor.constraint(equalToConstant: size)])
        font = Typography.system(size: TypeScale.heading, weight: TypeScale.emphasis)
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    /// The picture fills the disc; text (an emoji, initials) sits centered on the theme's fill.
    func show(picture: NSImage?, text: String?) {
        image = picture
        imagePosition = picture == nil ? .noImage : .imageOnly
        title = picture == nil ? (text ?? "") : ""
        applyTheme()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyTheme()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    private func applyTheme() {
        performWithTheme {
            layer?.backgroundColor = image == nil ? Palette.hoverFill.cgColor : nil
            contentTintColor = Palette.textPrimary
        }
    }
}

/// A borderless text button drawn as a plain link: the theme's accent (or
/// `ink`), underlined while hovered. Show Traces, Show Memory, Diagnostics.
@MainActor
final class HomeChiefLinkButton: NSButton {
    /// Nil draws the theme's accent.
    var ink: ThemeInk? { didSet { applyTitle() } }
    var textFont: NSFont = Typography.caption { didSet { applyTitle() } }
    private var text = ""
    private var isHovering = false { didSet { applyTitle() } }
    private var tracking: NSTrackingArea?

    init(title: String, target: AnyObject, action: Selector) {
        super.init(frame: .zero)
        text = title
        self.target = target
        self.action = action
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        setAccessibilityLabel(title)
        applyTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyTitle()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTitle()
    }

    private func applyTitle() {
        let color = performWithTheme { () -> NSColor in
            switch ink {
            case .primary?: Palette.textPrimary
            case .secondary?: Palette.textSecondary
            case .tertiary?: Palette.textTertiary
            case .danger?: Palette.danger
            case nil: Palette.accent
            }
        }
        var attributes: [NSAttributedString.Key: Any] = [.font: textFont, .foregroundColor: color]
        if isHovering { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        attributedTitle = NSAttributedString(string: text, attributes: attributes)
        invalidateIntrinsicContentSize()
    }
}
