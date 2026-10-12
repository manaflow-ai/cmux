public import CmuxUpdater
import Foundation
@preconcurrency import Sparkle

/// The changelog the update cards show for a found or staged update
/// (cx-lntk): from the Sparkle appcast item (its description and date), a
/// development build's probe, or the staged build's signed notes.
extension UpdaterService {
    /// The found update's changelog: Sparkle's offered item, else (no
    /// Sparkle) the probe's offered item.
    public var foundChangelog: UpdateChangelog? {
        if let controller, case .updateAvailable(let available) = controller.model.effectiveState {
            return Self.changelog(available.appcastItem)
        }
        guard case .updateAvailable(let item)? = lastProbe?.outcome else { return nil }
        return UpdateChangelog(version: item.displayVersion, date: item.date, description: item.itemDescription)
    }

    /// The staged update's changelog: the staged appcast item, its lines
    /// filled from the signed notes when the item has none.
    public var stagedChangelog: UpdateChangelog? {
        let fromNotes = stagedNotes.map { UpdateChangelog(notes: $0, version: stagedVersion) }
        guard let item = controller?.stagedUpdate else {
            return fromNotes ?? stagedVersion.map { UpdateChangelog(version: $0, date: nil, lines: []) }
        }
        var changelog = Self.changelog(item)
        if changelog.lines.isEmpty, let fromNotes {
            changelog.lines = fromNotes.lines
            changelog.date = changelog.date ?? fromNotes.date
        }
        return changelog
    }

    static func changelog(_ item: SUAppcastItem) -> UpdateChangelog {
        UpdateChangelog(version: item.displayVersionString, date: item.date, description: item.itemDescription)
    }
}
