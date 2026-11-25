public import CmuxNextSettings
import CmuxNextDesign
public import Foundation
import ImageIO
import os
import UniformTypeIdentifiers

/// The Make cmux Yours step's source over the app's settings owner (cmux#48416). Each pick is the
/// person's own write, made at once so the window behind shows it, as ONE publish of the settings
/// file with its linked edits (`SettingsController.setSettings`): the window never shows a half-done look.
/// - how they work: `tabs.newTabTemplate` `terminal` for terminal-first (a person's Cmd-T then opens a
///   terminal, cmux-window-rules `tabs::new_tab_kind`), removed for GUI-first (the New Tab page);
/// - density: `appearance.density` (a built-in ends a custom density; the reload applies the tokens);
/// - background: `appearance.background`, removed for none;
/// - its Opacity and Material: `appearance.backgroundOpacity` and `appearance.backgroundBlur`, the
///   rows Settings > Appearance draws under its background picker, removed when put back unset;
/// - where chats run: `agentPane.newChatsIn` `cloud`, removed for this Mac (the setting's default).
/// When the step opens it reads the file's own values at every path a pick may write, linked edits
/// included (`SettingsController.pathsWritten`); Skip writes exactly those back in one publish, so the
/// file is as it was at open, even over a person's own settings.
@MainActor
public final class FirstRunChoicesSettingsSource: FirstRunChoicesSource {
    /// The built-in backgrounds the step offers after None (cmux#49636): Shuffle Paintings, then
    /// well-known, calm works that read well behind text. Each has a bundled thumbnail; a work whose full
    /// image is not in the app downloads on its first pick. Settings > Appearance has the rest.
    nonisolated static let offered = [
        shuffleID,
        "van-gogh-starry-night", "hokusai-great-wave", "friedrich-wanderer", "dahl-dresden-moonlight", "monet-water-lilies-setting-sun",
        "hiroshige-kanbara-snow", "van-gogh-almond-blossom", "bruegel-hunters-snow", "roerich-himalayas", "vermeer-pearl-earring",
    ]
    /// Shuffle Paintings' `appearance.background` value: a new painting each day.
    nonisolated static let shuffleID = "daily"
    /// The work Shuffle Paintings' tile shows.
    nonisolated static let shufflePreview = "monet-impression-sunrise"

    /// The way to work the person picked on the step, if they changed it: read before its settings write lands,
    /// so the first chat (none for terminal-first) does not race a Return pressed right after the pick.
    public private(set) var pickedWorkStyle: WorkStyle?

    /// Called when a write was refused or failed, with what went wrong (`observeWriteFailures`).
    private var onWriteFailed: (@MainActor (String) -> Void)?

    /// Every path a pick writes, as the step offers them.
    nonisolated static let pickPaths: [[String]] = [
        NewTabTemplate.configPath, DensitySetting.configPath, BackdropSelectionSetting.configPath,
        WindowBackgroundSetting.opacityPath, WindowBackgroundSetting.materialPath, newChatsInPath,
    ]
    /// `agentPane.newChatsIn` (Settings > Start New Chats In).
    nonisolated static let newChatsInPath = ["agentPane", "newChatsIn"]

    /// Every other path the intro walk writes: the look bundles (two-tone, calm, motion), the trust row
    /// (the agents' permission), the noise row (banners and sound) and Tidy (archiving and settling).
    /// Read at open with the picks' paths, so Skip puts them back too.
    nonisolated static let walkPaths: [[String]] = [
        ["agents", "defaultPermissionMode"],
        ["notifications", "desktop"], ["notifications", "sound"], ["notifications", "sounds", "when"],
        ["appearance", "twoTone"], ["ui", "calm"], ["ui", "animations", "enabled"],
        ["agents", "chats", "archiveInactive"], ["workspaces", "autoArchive", "style"], ["sidebar", "settleFinished"],
    ]

    private let settings: @MainActor () -> SettingsController?
    private let windowOpacity: @MainActor () -> Double?
    private let log = Logger(subsystem: "com.cmuxterm.app.next", category: "onboarding")

    /// One queued step of the writer: read the file at open, write a pick's batch, or put back what was read.
    private enum Work {
        case capture
        case write([(path: [String], value: JSONValue?)])
        case restore
    }

    /// The work not yet done, oldest first. Picks queued behind each other merge into one batch (a
    /// slider's steps coalesce into its last value per setting).
    private var pending: [Work] = []
    private var writer: Task<Void, Never>?
    /// The file's values at open (`capture`), for Skip.
    private var opened: SettingsFileValues?
    /// The work style when the step opened, for `pickedWorkStyle` after Skip.
    private var openedWorkStyle: WorkStyle?
    /// `markOpened` asked for the read (it may still be running).
    private var captureAsked = false
    /// The open-time read threw: Skip has nothing to put back, so the caller writes the old choices.
    private var captureFailed = false

    /// `settings` is the app's settings owner (nil before it started); `windowOpacity` reads the
    /// opacity the window shows now (Settings' unset slider's reading).
    public init(settings: @escaping @MainActor () -> SettingsController?,
                windowOpacity: @escaping @MainActor () -> Double? = { nil }) {
        self.settings = settings
        self.windowOpacity = windowOpacity
    }

    public func currentChoices() -> FirstRunChoices {
        guard let snapshot = settings()?.snapshot else { return .recommended }
        let template = snapshot.root.value(at: ["tabs", "newTabTemplate"])?.stringValue
        let background = snapshot.root.value(at: ["appearance", "background"])?.stringValue
        let runIn = snapshot.root.value(at: Self.newChatsInPath)?.stringValue
        return FirstRunChoices(workStyle: template == "terminal" ? .terminal : .gui,
                               density: Self.density(snapshot.density),
                               background: background == "none" ? nil : background,
                               opacity: snapshot.windowBackground.opacity,
                               material: snapshot.windowBackground.material.flatMap { FirstRunMaterial(rawValue: $0.rawValue) },
                               chatsRunIn: runIn == "cloud" ? .cloud : .local)
    }

    /// The density setting as a preset id: unset is Settings' Default.
    static func density(_ value: String?) -> String {
        value.flatMap(DensityPreset.init(rawValue:))?.rawValue ?? value ?? FirstRunChoices.defaultDensity
    }

    /// Every built-in density, in Settings' order and by Settings' names.
    public func densities() -> [FirstRunDensity] { Self.densities }

    static var densities: [FirstRunDensity] {
        DensityPreset.allCases.map { FirstRunDensity(id: $0.rawValue, name: DensityNames().name($0.tokens)) }
    }

    public func shownOpacity() -> Double? { windowOpacity() }

    public func backgrounds() async -> [FirstRunBackground] {
        // Shuffle Paintings is a mode, not a work: no name (the page says it in its language), a painting's preview.
        let rows: [(id: String, name: String, url: URL?)] = Self.offered.compactMap { id in
            if id == Self.shuffleID { return (id, "", BackdropSelection(id: Self.shufflePreview)?.thumbnailURL) }
            guard let selection = BackdropSelection(id: id) else { return nil }
            return (id, selection.title, selection.thumbnailURL)
        }
        let previews = await Self.previews(rows.map(\.url))
        return zip(rows, previews).map { FirstRunBackground(id: $0.id, name: $0.name, preview: $1) }
    }

    /// Reads the file's values at every path a pick may write (absent ones too), before any pick.
    /// The read queues after a restore still waiting from the window before (a quick reopen from the
    /// palette), so that Skip puts back its own snapshot before this one is taken.
    public func markOpened() {
        captureAsked = true
        captureFailed = false
        openedWorkStyle = currentChoices().workStyle
        pickedWorkStyle = nil
        pending.removeAll { if case .capture = $0 { true } else { false } }
        let afterRestore = pending.lastIndex { if case .restore = $0 { true } else { false } }.map { $0 + 1 } ?? 0
        pending.insert(.capture, at: afterRestore)
        drain()
    }

    public func apply(_ new: FirstRunChoices, from old: FirstRunChoices) {
        if new.workStyle != old.workStyle { pickedWorkStyle = new.workStyle }
        var writes: [(path: [String], value: JSONValue?)] = []
        if new.workStyle != old.workStyle { writes.append((NewTabTemplate.configPath, new.workStyle == .terminal ? .string("terminal") : nil)) }
        if new.density != old.density { writes.append((DensitySetting.configPath, .string(new.density))) }
        if new.background != old.background { writes.append((BackdropSelectionSetting.configPath, new.background.map(JSONValue.string))) }
        if new.opacity != old.opacity { writes.append((WindowBackgroundSetting.opacityPath, new.opacity.map(JSONValue.number))) }
        if new.material != old.material { writes.append((WindowBackgroundSetting.materialPath, new.material.map { .string($0.rawValue) })) }
        if new.chatsRunIn != old.chatsRunIn { writes.append((Self.newChatsInPath, new.chatsRunIn == .cloud ? .string("cloud") : nil)) }
        enqueue(writes)
    }

    public func introWalk() -> Bool {
        settings()?.snapshot.root.value(at: CmuxConfigSnapshot.introWalkPath)?.boolValue ?? CmuxConfigSnapshot.introWalkDefault
    }

    public func walkValues() -> [String: JSONValue] {
        guard let root = settings()?.snapshot.root else { return [:] }
        var values: [String: JSONValue] = [:]
        for path in Self.walkPaths {
            if let value = root.value(at: path) { values[path.joined(separator: ".")] = value }
        }
        return values
    }

    public func applyWalk(_ writes: [FirstRunWalkWrite]) -> Bool {
        let allowed = Set(Self.pickPaths + Self.walkPaths)
        guard writes.allSatisfy({ allowed.contains($0.path) }) else { return false }
        if let template = writes.last(where: { $0.path == NewTabTemplate.configPath }) {
            pickedWorkStyle = template.value?.stringValue == "terminal" ? .terminal : .gui
        }
        enqueue(writes.map { (path: $0.path, value: $0.value) })
        return true
    }

    /// Queues `writes` as one batch, merged into a batch still waiting (the last value per path wins).
    private func enqueue(_ writes: [(path: [String], value: JSONValue?)]) {
        guard !writes.isEmpty else { return }
        if case .write(var queued)? = pending.last {
            for write in writes {
                if let index = queued.firstIndex(where: { $0.path == write.path }) { queued.remove(at: index) }
                queued.append(write)
            }
            pending[pending.count - 1] = .write(queued)
        } else {
            pending.append(.write(writes))
        }
        drain()
    }

    /// Skip: puts back the file's values from open in one publish (nothing when no pick changed them).
    /// False when the step never read them (no settings owner, or the read threw): the caller writes the old choices instead.
    public func restoreOpened() -> Bool {
        guard captureAsked, !captureFailed else { return false }
        if pickedWorkStyle != nil { pickedWorkStyle = openedWorkStyle }
        // Picks not yet written never need writing: the restore puts their paths back anyway.
        pending.removeAll { if case .write = $0 { true } else { false } }
        pending.append(.restore)
        drain()
        return true
    }

    public func observeWriteFailures(_ handler: @escaping @MainActor (String) -> Void) {
        onWriteFailed = handler
    }

    /// Waits until every queued write has landed (tests, and a caller that must read after Skip).
    public func settled() async {
        while let writer { await writer.value }
    }

    /// Does the queued work one step at a time, in the order it was asked: two picks in a row (or a
    /// dragged slider) never land out of order, and Skip lands after every pick before it.
    private func drain() {
        guard writer == nil, !pending.isEmpty else { return }
        // task-owner: the one writer of the step's picks; it ends when nothing is pending.
        writer = Task { [weak self] in
            while let self, !pending.isEmpty {
                let work = pending.removeFirst()
                guard let settings = settings() else {
                    if case .capture = work { opened = nil; captureFailed = true }
                    failed("settings are not started")
                    continue
                }
                do {
                    switch work {
                    case .capture:
                        opened = nil
                        do {
                            opened = try await settings.fileValues(at: SettingsController.pathsWritten(by: Self.pickPaths + Self.walkPaths))
                        } catch {
                            captureFailed = true
                            throw error
                        }
                    case .write(let writes):
                        try await settings.setSettings(writes, by: .user)
                    case .restore:
                        guard let opened else {
                            failed("Skip could not put the settings back: they were not read at open")
                            continue
                        }
                        try await settings.restore(opened)
                    }
                } catch {
                    failed(String(describing: error))
                }
            }
            self?.writer = nil
        }
    }

    private func failed(_ reason: String) {
        log.error("first-run choices not saved: \(reason, privacy: .public)")
        onWriteFailed?(reason)
    }

    /// Small `data:` PNGs of `urls`, decoded off the main actor (nil for a missing file).
    @concurrent nonisolated static func previews(_ urls: [URL?]) async -> [String?] {
        urls.map { url in url.flatMap(preview(at:)) }
    }

    /// A PNG at most 160 pixels wide of the image at `url`, as a `data:` URL.
    nonisolated static func preview(at url: URL) -> String? {
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: 160] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return "data:image/png;base64," + (data as Data).base64EncodedString()
    }
}
