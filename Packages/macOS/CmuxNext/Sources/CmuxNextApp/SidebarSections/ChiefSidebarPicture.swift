import CmuxNextChiefPetWiring
import CmuxNextCompat
import CmuxNextFloating
import CmuxNextSidebar
import CmuxNextWakeups
import CoreGraphics
import Foundation
import Observation

/// The sidebar's Chief item picture: the default Chief's own upload's first frame, else the chosen
/// pet character (`home.chiefPetMascot`) as its avatar (the whole character on a transparent square),
/// drawn untinted as the item's glyph in every look, as the Home header wears it. One image per
/// picture file, so the same pick compares equal and an unrelated sidebar change does not redraw the item.
///
/// The bundled PNG is read and decoded on the files lane, never on the main thread (Chrome decodes
/// images off its UI thread: services/data_decoder/public/cpp/decode_image.h): until it lands the
/// item keeps its plain glyph, and the sidebar's observation redraws it when ``favicon(mascot:picture:image:)``
/// changes. An upload comes already decoded by ``ChiefAvatarUploads`` (its first frame) or not at all.
/// The app has one (``AppServices/chiefSidebarPicture``), so a window opened after the
/// first load draws the picture in its first frame, and each file is read once per launch: a file
/// that failed to load is not read again.
@MainActor @Observable
final class ChiefSidebarPicture {
    private var loaded: [URL: SidebarFavicon] = [:]
    /// Uploads' pictures, made from their already decoded first frame; an upload's file name is new
    /// per upload, so a new one is never the cached old one. Filled while an observation reads, so
    /// not observed itself (the upload's image is).
    @ObservationIgnored private var uploaded: [URL: SidebarFavicon] = [:]
    @ObservationIgnored private var loading: Set<URL> = []
    /// The files that could not be read or decoded; a later ``load(mascot:picture:)`` of one does nothing.
    @ObservationIgnored private var failed: Set<URL> = []
    @ObservationIgnored private let work: BackgroundWork
    @ObservationIgnored private let mainWork: MainWorkScheduler

    /// - Parameters:
    ///   - work: The lanes the file is read and decoded on.
    ///   - mainWork: The main-thread scheduler the picture lands through, as visible work.
    init(work: BackgroundWork, mainWork: MainWorkScheduler) {
        self.work = work
        self.mainWork = mainWork
    }

    /// `picture` (`AppServices.characterPicture(of:)`): a worn upload comes with its first frame
    /// `image`, decoded off the main actor by ``ChiefAvatarUploads``; else the picture of the
    /// character `mascot` names (an unknown or nil id: orb) once it is loaded. Nil before
    /// ``load(mascot:picture:)`` ends or when the bundled file cannot be read. Reading it in an
    /// observation tracks the load.
    func favicon(mascot: String?, picture: URL? = nil, image: CGImage? = nil) -> SidebarFavicon? {
        guard let url = picture ?? ChiefPetSettingsRows.avatarURL(of: mascot) else { return nil }
        if let known = loaded[url] { return known }
        guard let image else { return nil }
        if let known = uploaded[url] { return known }
        let favicon = SidebarFavicon(image)
        uploaded[url] = favicon
        return favicon
    }

    /// Reads and decodes the picture of `mascot` (or `picture`, when it is a character's own picture
    /// in the app) on the files lane, when it is not loaded, loading or failed; the result lands on
    /// main as visible work (PostTaskAndReply). An upload is never read here: it comes decoded.
    ///
    /// - Parameters:
    ///   - mascot: The pet character's id.
    ///   - picture: The picture ``AppServices/characterPicture(of:)`` named, if any.
    /// - Returns: Whether a load started.
    @discardableResult
    func load(mascot: String?, picture: URL? = nil) -> Bool {
        guard let url = picture ?? ChiefPetSettingsRows.avatarURL(of: mascot),
              ChiefPetMascot.allCases.contains(where: { $0.avatarURL == url }) || picture == nil,
              loaded[url] == nil, !failed.contains(url), loading.insert(url).inserted else { return false }
        work.run(.userVisible, mayBlock: .files) { CheckedImageSource(blockingContentsOf: url)?.image() }
            .reply(on: mainWork, class: .visible, owner: "sidebar.chiefPicture") { [weak self] image in
                self?.finish(url, image)
            }
        return true
    }

    private func finish(_ url: URL, _ image: CGImage?) {
        loading.remove(url)
        if let image { loaded[url] = SidebarFavicon(image) } else { failed.insert(url) }
    }
}
