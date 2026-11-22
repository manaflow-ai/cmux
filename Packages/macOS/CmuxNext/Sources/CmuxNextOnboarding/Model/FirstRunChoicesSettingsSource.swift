public import CmuxNextSettings
import CmuxNextDesign
public import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The Make cmux Yours step's source over the app's settings owner (cmux#48416). Each pick is the
/// person's own write, made at once through Settings so the window behind shows it.
@MainActor
public final class FirstRunChoicesSettingsSource: FirstRunChoicesSource {
    /// The built-in backgrounds the step offers after None: Shuffle Paintings, then a few calm works
    /// from the bundled art (Settings > Personalization has the rest).
    nonisolated static let offered = [shuffleID, "friedrich-forest-moonlight", "hogai-nio", "klee-fish-magic", "rembrandt-storm-galilee"]
    /// Shuffle Paintings' `appearance.background` value: a new painting each day.
    nonisolated static let shuffleID = "daily"
    /// The work Shuffle Paintings' tile shows.
    nonisolated static let shufflePreview = "munch-scream"

    private let settings: @MainActor () -> SettingsController?

    /// `settings` is the app's settings owner (nil before it started).
    public init(settings: @escaping @MainActor () -> SettingsController?) {
        self.settings = settings
    }

    public func currentChoices() -> FirstRunChoices {
        guard let snapshot = settings()?.snapshot else { return .recommended }
        // Keep source modes like Shuffle Paintings instead of the picture they display today.
        let background = snapshot.root.value(at: BackdropSelectionSetting.configPath)?.stringValue
            ?? snapshot.backdropSelection?.id
        let density = snapshot.selectedDensity
        return FirstRunChoices(workStyle: snapshot.newTabTemplate == .terminal ? .terminal : .gui,
                               density: Self.density(density.basedOn ?? density.id),
                               background: background == BackdropSelectionSetting.fallback ? nil : background)
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

    public func apply(_ new: FirstRunChoices, from old: FirstRunChoices) async throws {
        guard let settings = settings() else { throw SettingsWriterDisconnected() }
        if new.workStyle != old.workStyle {
            let template: NewTabTemplate = new.workStyle == .terminal ? .terminal : .minimal
            try await settings.setSetting(at: NewTabTemplate.configPath, to: .string(template.rawValue), by: .user)
        }
        if new.density != old.density {
            try await settings.setSetting(at: DensitySetting.configPath, to: .string(Self.preset(new.density)), by: .user)
        }
        if new.background != old.background {
            try await settings.setSetting(at: BackdropSelectionSetting.configPath,
                                          to: .string(new.background ?? BackdropSelectionSetting.fallback), by: .user)
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
