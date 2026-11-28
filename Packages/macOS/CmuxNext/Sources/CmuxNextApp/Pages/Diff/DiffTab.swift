import CmuxNextSettings
import Foundation

/// What a diff tab has once its repository is known: the grant its sidecar
/// requests run under and the config its page boots from.
nonisolated struct DiffTabReady: Sendable {
    let grant: DiffSessionGrant
    let config: JSONValue
}

/// Why a diff tab has no grant (shown by the page as its status message).
nonisolated struct DiffTabFailure: Error, Sendable, Equatable {
    let title: String
    let message: String
}

/// What a diff tab asks of its owner (``DiffPageService``) for the empty state
/// (diff-host.md "Empty state"): find a folder's repository, make a grant for
/// it, the recents, the folder picker, and "this tab now shows `repository`"
/// (which records the recent and retitles the tab).
protocol DiffTabHosting: AnyObject {
    func repository(at folder: URL) async -> DiffRepository?
    func prepare(_ repository: DiffRepository, source: DiffOpenSource) -> Task<DiffTabReady, any Error>
    func recents() async -> JSONValue
    func chooseFolder(start: URL?) async -> URL?
    func opened(_ repository: DiffRepository, source: DiffOpenSource)
}
