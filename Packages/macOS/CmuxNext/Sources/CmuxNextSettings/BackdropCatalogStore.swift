public import CmuxNextDesign
import Foundation
public import Observation

/// The wallpaper grid's choices (Appearance settings), listed off the main actor.
///
/// A listing reads the macOS Desktop Pictures folder, every `.madesktop` description, the
/// downloaded wallpaper assets, the aerials and the person's backgrounds folder: tens of
/// milliseconds of file reads. It ran on the main actor each time the Settings page's host lists
/// were read again, which is after any settings write while a Settings page exists (sweep
/// 2026-10-23: `AppleWallpapers.pictures` and `AppleWallpaper.init` in 35 main-thread stalls, up
/// to 190 ms in STRESS). The store lists on a background task when it is asked to (each Settings
/// opening, a new Settings page, an image the person adds) and keeps the last listing until the
/// next one is ready, so a read is a stored value. The listing and its page rows are observable:
/// the Settings page's host-lists watch sends the new list when a listing lands.
///
/// Tests pass a lister over a temporary folder:
///
/// ```swift
/// let store = BackdropCatalogStore { BackdropCatalog(systemDirectory: folder, fileManager: .default, assets: .none) }
/// store.refresh()
/// ```
@MainActor @Observable
public final class BackdropCatalogStore {
    /// The last listing: ``BackdropCatalog/unlisted`` until the first one lands.
    public private(set) var catalog = BackdropCatalog.unlisted
    /// ``catalog``'s Settings page rows (`BackdropCatalog.pageRows`), built once per listing.
    public private(set) var pageRows: JSONValue

    /// Builds a full catalog; called off the main actor.
    @ObservationIgnored private let list: @Sendable () -> BackdropCatalog
    /// The listing in flight, if any.
    @ObservationIgnored private var listing: Task<Void, Never>?
    /// A refresh arrived while a listing was in flight: list once more after it.
    @ObservationIgnored private var listAgain = false
    /// How many listings started (tests).
    @ObservationIgnored private(set) var listings = 0

    /// - Parameter list: Builds the catalog. It runs on a background task, never on the main actor.
    public init(list: @escaping @Sendable () -> BackdropCatalog) {
        self.list = list
        pageRows = BackdropCatalog.unlisted.pageRows
    }

    /// Lists the folders again on a background task. A refresh while one runs lists once more
    /// after it (the folders may have changed since it started); more refreshes meanwhile add
    /// nothing. The catalog changes only when the new listing differs.
    public func refresh() {
        guard listing == nil else {
            listAgain = true
            return
        }
        listings += 1
        let list = list
        // task-owner: one listing at a time; it ends after one folder read and, when asked meanwhile, starts the next
        listing = Task { [weak self] in
            let next = await Task.detached(priority: .userInitiated) { list() }.value
            guard let self else { return }
            self.listing = nil
            if next != self.catalog {
                self.catalog = next
                self.pageRows = next.pageRows
            }
            if self.listAgain {
                self.listAgain = false
                self.refresh()
            }
        }
    }

    /// Waits for the listing in flight, if any (tests).
    func settle() async {
        while let listing {
            await listing.value
        }
    }
}
