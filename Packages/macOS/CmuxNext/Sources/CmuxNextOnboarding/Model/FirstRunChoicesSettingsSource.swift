public import CmuxNextSettings
import CmuxNextDesign
public import Foundation
import ImageIO
import os
import UniformTypeIdentifiers

/// The Make cmux Yours step's source over the app's settings owner (cmux#48416). Each pick is the
/// person's own write, made at once so the window behind shows it:
/// - how they work: `tabs.newTabTemplate` `terminal` for terminal-first (a person's Cmd-T then opens a
///   terminal, cmux-window-rules `tabs::new_tab_kind`), removed for GUI-first (the New Tab page);
/// - density: through the App's `appearance.density.set` (`setDensity`), which also applies the tokens;
/// - background: `appearance.background`, removed for none;
/// - where chats run: `agentPane.newChatsIn` `cloud`, removed for this Mac (the setting's default).
@MainActor
public final class FirstRunChoicesSettingsSource: FirstRunChoicesSource {
    /// The built-in backgrounds the step offers after None: Shuffle Paintings, then a few calm works
    /// from the bundled art (Settings > Personalization has the rest).
    nonisolated static let offered = [shuffleID, "friedrich-forest-moonlight", "hogai-nio", "klee-fish-magic", "rembrandt-storm-galilee"]
    /// Shuffle Paintings' `appearance.background` value: a new painting each day.
    nonisolated static let shuffleID = "daily"
    /// The work Shuffle Paintings' tile shows.
    nonisolated static let shufflePreview = "munch-scream"

    /// The way to work the person picked on the step, if they changed it: read before its settings write lands,
    /// so the first chat (none for terminal-first) does not race a Return pressed right after the pick.
    public private(set) var pickedWorkStyle: WorkStyle?

    private let settings: @MainActor () -> SettingsController?
    private let setDensity: @MainActor (String) -> Void
    private let log = Logger(subsystem: "com.cmuxterm.app.next", category: "onboarding")

    /// `settings` is the app's settings owner (nil before it started); `setDensity` runs the density
    /// action with a preset id (`compact`, `cozy`, `comfortable`).
    public init(settings: @escaping @MainActor () -> SettingsController?, setDensity: @escaping @MainActor (String) -> Void) {
        self.settings = settings
        self.setDensity = setDensity
    }

    public func currentChoices() -> FirstRunChoices {
        guard let snapshot = settings()?.snapshot else { return .recommended }
        let template = snapshot.root.value(at: ["tabs", "newTabTemplate"])?.stringValue
        let background = snapshot.root.value(at: ["appearance", "background"])?.stringValue
        let runIn = snapshot.root.value(at: ["agentPane", "newChatsIn"])?.stringValue
        return FirstRunChoices(workStyle: template == "terminal" ? .terminal : .gui,
                               density: Self.density(snapshot.density),
                               background: background == "none" ? nil : background,
                               chatsRunIn: runIn == "cloud" ? .cloud : .local)
    }

    /// A density setting as the step's three choices: the smaller and larger extremes go to their neighbor.
    nonisolated static func density(_ value: String?) -> DensityChoice {
        switch value {
        case "ultraCompact", "compact": .compact
        case "comfortable", "spacious": .comfortable
        default: .standard
        }
    }

    /// The density preset a choice writes.
    nonisolated static func preset(_ choice: DensityChoice) -> String {
        switch choice {
        case .compact: "compact"
        case .standard: "cozy"
        case .comfortable: "comfortable"
        }
    }

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

    public func apply(_ new: FirstRunChoices, from old: FirstRunChoices) {
        if new.workStyle != old.workStyle { pickedWorkStyle = new.workStyle }
        if new.density != old.density { setDensity(Self.preset(new.density)) }
        guard let settings = settings() else { return }
        var writes: [([String], JSONValue?)] = []
        if new.workStyle != old.workStyle { writes.append((["tabs", "newTabTemplate"], new.workStyle == .terminal ? .string("terminal") : nil)) }
        if new.background != old.background { writes.append((["appearance", "background"], new.background.map(JSONValue.string))) }
        if new.chatsRunIn != old.chatsRunIn { writes.append((["agentPane", "newChatsIn"], new.chatsRunIn == .cloud ? .string("cloud") : nil)) }
        guard !writes.isEmpty else { return }
        // task-owner: one settings write per pick; the settings owner serializes them.
        Task { [log, writes] in
            for (path, value) in writes {
                do {
                    try await settings.setSetting(at: path, to: value, by: .user)
                } catch {
                    log.error("first-run choice \(path.joined(separator: "."), privacy: .public) refused: \(String(describing: error), privacy: .public)")
                }
            }
        }
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
