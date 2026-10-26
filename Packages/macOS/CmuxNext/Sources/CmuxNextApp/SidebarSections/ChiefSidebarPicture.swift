import CmuxNextChiefPetWiring
import CmuxNextCompat
import CmuxNextSidebar
import CmuxNextWakeups
import Foundation
import ImageIO
import Observation

/// The sidebar's Chief item picture: the chosen pet character (`home.chiefPetMascot`) as its
/// avatar (the whole character on a transparent square), drawn untinted as the item's glyph in
/// every look, as the Home header wears it. One image per character, so the same pick compares
/// equal and an unrelated sidebar change does not redraw the item.
///
/// The bundled PNG is read and decoded on the files lane, never on the main thread (Chrome decodes
/// images off its UI thread: services/data_decoder/public/cpp/decode_image.h): until it lands the
/// item keeps its plain glyph, and the sidebar's observation redraws it when ``favicon(mascot:)``
/// changes.
@MainActor @Observable
final class ChiefSidebarPicture {
    private var loaded: [URL: SidebarFavicon] = [:]
    @ObservationIgnored private var loading: [URL: Task<Void, Never>] = [:]
    @ObservationIgnored private let work: BackgroundWork

    init(work: BackgroundWork) {
        self.work = work
    }

    /// The picture of the character `mascot` names (an unknown or nil id: orb) once it is loaded;
    /// nil before ``load(mascot:)`` ends or when the bundled file cannot be read. Reading it in an
    /// observation tracks the load.
    func favicon(mascot: String?) -> SidebarFavicon? {
        ChiefPetSettingsRows.avatarURL(of: mascot).flatMap { loaded[$0] }
    }

    /// Loads the picture of `mascot` on the files lane when it is not loaded or loading.
    ///
    /// - Parameter mascot: The pet character's id.
    /// - Returns: The load, for a caller that waits for it; nil when there is nothing to load.
    @discardableResult
    func load(mascot: String?) -> Task<Void, Never>? {
        guard let url = ChiefPetSettingsRows.avatarURL(of: mascot), loaded[url] == nil else { return nil }
        if let running = loading[url] { return running }
        let work = work
        // task-owner: one bundled PNG read; ends when the files lane returns it
        let task = Task { [weak self] in
            let image = try? await work.run(.userVisible, mayBlock: .files) {
                CheckedImageSource(blockingContentsOf: url)?.image(options: [kCGImageSourceShouldCacheImmediately: true])
            }
            guard let self else { return }
            loading[url] = nil
            if let image = image ?? nil { loaded[url] = SidebarFavicon(image) }
        }
        loading[url] = task
        return task
    }
}
