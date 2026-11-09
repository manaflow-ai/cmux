// cmux: the skills a Chief chat's `/` menu offers, read off the main thread and kept for the menu.
// Not a vendored file.
import Foundation

/// Holds the last list ``SlashSkillCatalog/load()`` gave and refreshes it in the background.
///
/// The menu reads ``skills`` at once (the last list, empty before the first load); each
/// ``refresh()`` reads the folders again on a background task and calls ``onChange`` with the
/// new list, so a skill added while the app runs shows the next time `/` is typed.
/// Main thread only (the field's delegate calls it; its load ends on the main actor).
final class SlashSkillSource {
    /// The folders to read.
    let catalog: SlashSkillCatalog
    /// The last list read; empty until the first load ends.
    private(set) var skills: [SlashSkill] = []
    /// The list changed (a load ended with another list).
    var onChange: () -> Void = {}
    /// The running load, if any.
    private var loading: Task<Void, Never>?

    /// - Parameter catalog: The folders the skills come from.
    init(catalog: SlashSkillCatalog) {
        self.catalog = catalog
    }

    /// Reads the folders again off the main thread, unless a read runs already.
    func refresh() {
        guard loading == nil else { return }
        let catalog = catalog
        // task-owner: this source; one bounded folder read, then it ends
        loading = Task { @MainActor [weak self] in
            let fresh = await Task.detached(priority: .userInitiated) { catalog.load() }.value
            guard let self else { return }
            loading = nil
            guard fresh != skills else { return }
            skills = fresh
            onChange()
        }
    }

    /// Waits for the running read (tests).
    func settled() async { await loading?.value }
}
