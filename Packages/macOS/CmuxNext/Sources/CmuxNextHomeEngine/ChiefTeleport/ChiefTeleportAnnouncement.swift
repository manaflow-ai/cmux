public import Foundation

/// A teleport event the Chief chat announces once (``ChiefTeleportNotice``): the Chief moved, moved back
/// or was forked, seen happening while the app ran. It comes from a change between two reads of the
/// home's marks, never from the first read: a fork or move made before launch is not news, and a
/// reload or relaunch does not bring the row back.
public nonisolated enum ChiefTeleportAnnouncement: Equatable, Sendable {
    /// The Chief now runs at this place; when the move ended.
    case moved(ChiefLocation, at: Date?)
    /// The Chief answers from this Mac again.
    case movedBack
    /// A new fork in cmux Cloud, by its name; when it was made.
    case forked(String, at: Date?)

    /// The event between two reads of a home's marks; nil when nothing to announce changed.
    ///
    /// - Parameters:
    ///   - old: The marks the app had.
    ///   - new: The marks it read now.
    public init?(from old: ChiefHomeMarks, to new: ChiefHomeMarks) {
        let place = new.whereabouts.location
        if place != old.whereabouts.location {
            self = place == .thisMac ? .movedBack : .moved(place, at: new.movedAt)
        } else if let fork = new.fork, fork.chief != old.fork?.chief {
            self = .forked(fork.name, at: fork.at)
        } else {
            return nil
        }
    }
}
