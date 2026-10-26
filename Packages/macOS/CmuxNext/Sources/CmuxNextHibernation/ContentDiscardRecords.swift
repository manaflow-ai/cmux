/// What discarded content keeps until it is made again, and the picture each item's last hide took,
/// by its owner's key (page tabs: the provider key). Bookkeeping only: ``ContentDiscardScheduler``
/// says when content goes, and the owner makes and tears down its views. Chrome keeps a discarded
/// tab's navigation entries (its URL, scroll and form state) the same way while its renderer is gone
/// (content/public/browser/navigation_entry.h).
@MainActor
package final class ContentDiscardRecords {
    /// What a discarded item keeps until it is made again.
    package struct Record: Sendable {
        /// What its view showed besides its route.
        package var state: ContentViewState
        /// What it showed (a page tab's route), given back before its next view is made.
        package var route: String?

        package init(state: ContentViewState, route: String?) {
            self.state = state
            self.route = route
        }
    }

    /// The picture an item's hide took: the capture on its way, then the version of what it shows.
    package struct Picture {
        package var task: Task<Void, Never>?
        /// The owner's version of what the stored picture shows; nil until a capture landed.
        package var version: Int?

        package init(task: Task<Void, Never>?, version: Int?) {
            self.task = task
            self.version = version
        }
    }

    package var discarded: [String: Record] = [:]
    package var pictures: [String: Picture] = [:]

    package init() {}

    /// `key` closed: nothing of it stays, and a capture on its way stops.
    package func forget(_ key: String) {
        discarded[key] = nil
        pictures.removeValue(forKey: key)?.task?.cancel()
    }
}
