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
    /// The folders to read; nil for a Chief whose host runs elsewhere (``remote``).
    let catalog: SlashSkillCatalog?
    /// The remote Chief this list asks (``RemoteSlashSkills/id``); nil for folders.
    let remoteID: String?
    /// Reads the list off this Mac: folders, or the remote Chief's answer.
    /// nil: the read failed (a remote host that did not answer).
    private let read: @Sendable () async -> [SlashSkill]?
    /// The last list read; empty until the first load ends.
    private(set) var skills: [SlashSkill] = []
    /// The list changed (a load ended with another list).
    var onChange: () -> Void = {}
    /// The running load, if any.
    private var loading: Task<Void, Never>?
    /// A load has ended (until then an empty ``skills`` means "not here yet").
    private(set) var hasLoaded = false
    /// The newest read failed (the remote host did not answer); ``skills`` keeps the last list.
    private(set) var failed = false

    /// - Parameter catalog: The folders the skills come from.
    init(catalog: SlashSkillCatalog) {
        self.catalog = catalog
        remoteID = nil
        read = { await Task.detached(priority: .userInitiated) { catalog.load() }.value }
    }

    /// - Parameter remote: The Chief host that names its skills (a paired server's).
    init(remote: RemoteSlashSkills) {
        catalog = nil
        remoteID = remote.id
        read = remote.load
    }

    /// Reads the list again, unless a read runs already.
    func refresh() {
        guard loading == nil else { return }
        let read = read
        // task-owner: this source; one bounded folder read or one engine request, then it ends
        loading = Task { @MainActor [weak self] in
            let fresh = await read()
            guard let self else { return }
            loading = nil
            let first = !hasLoaded
            hasLoaded = true
            let failedNow = fresh == nil
            let failedChanged = failedNow != failed
            failed = failedNow
            guard let fresh else {
                if first || failedChanged { onChange() }
                return
            }
            guard first || failedChanged || fresh != skills else { return }
            skills = fresh
            onChange()
        }
    }

    /// Waits for the running read (tests).
    func settled() async { await loading?.value }
}

/// The skills of a Chief whose host runs on another machine (a paired server): its
/// `chief.engine.get` answer names them (`offered.skills`), since this Mac cannot read its folders.
public struct RemoteSlashSkills: Sendable {
    /// Which Chief; a new id makes a new list.
    public let id: String
    /// Asks the Chief's host for its list (nil when it does not answer).
    public let load: @Sendable () async -> [SlashSkill]?

    /// - Parameters:
    ///   - id: Which Chief.
    ///   - load: Asks its host for the list; nil when it did not answer.
    public init(id: String, load: @escaping @Sendable () async -> [SlashSkill]?) {
        self.id = id
        self.load = load
    }
}
