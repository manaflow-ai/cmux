import Foundation

/// "What's in this build" (Leo 2026-11-26: "hm do we display which prs go into which nightly maybe
/// that'd be useful per thing?"): the update prompt lists the PRs merged after this build through
/// the staged one, and About lists the running build's own, each from the feed's verified notes.
extension UpdaterService {
    /// Builds a span reads notes for at most: a Mac many nightlies behind lists the newest ones.
    static let pullRequestSpanLimit = 40

    /// Reads the staged span's PRs once per staged build: the feed's index picks the builds after
    /// this one through the staged one, and each build's verified notes give its PRs.
    @discardableResult
    func loadStagedPullRequests() -> Task<Void, Never>? {
        guard let staged = stagedBuild(), stagedPullRequestsTask?.build != staged else { return nil }
        stagedPullRequestsTask?.task.cancel()
        let installed = identity.build
        let index = spanIndexLoader
        let load = spanNotesLoader
        let task = Task { [weak self] in
            let builds = BuildPullRequests.builds(in: await index(), after: installed, through: staged)
            var notes: [ReleaseNotes] = []
            for build in builds.prefix(Self.pullRequestSpanLimit) {
                guard !Task.isCancelled else { return }
                if let read = await load(build) { notes.append(read) }
            }
            let list = BuildPullRequests(notes: notes)
            guard let self, !Task.isCancelled, self.stagedPullRequestsTask?.build == staged else { return }
            self.stagedPullRequests = list
            self.log.append("staged PRs: \(installed)...\(staged) \(builds.count) builds, \(list.count) PRs")
        }
        stagedPullRequestsTask = (staged, task)
        return task
    }

    func clearStagedPullRequests() {
        stagedPullRequestsTask?.task.cancel()
        stagedPullRequestsTask = nil
        if stagedPullRequests != nil { stagedPullRequests = nil }
    }

    /// About's "What's in this build": the running build's own notes' PRs; empty without them.
    public func currentBuildPullRequests() async -> BuildPullRequests {
        let build = identity.build
        guard !build.isEmpty else { return BuildPullRequests(notes: []) }
        let notes = await spanNotesLoader(build)
        return BuildPullRequests(notes: notes.map { [$0] } ?? [])
    }

    private var spanNotesLoader: @Sendable (String) async -> ReleaseNotes? {
        notesLoader ?? { [releaseNotes] build in await releaseNotes?.notes(for: build) }
    }

    /// The index reader; a test that replaced only the notes reader reads no index (no network).
    private var spanIndexLoader: @Sendable () async -> [ReleaseNotesIndexEntry] {
        if let indexLoader { return indexLoader }
        if notesLoader != nil { return { [] } }
        return { [releaseNotes] in await releaseNotes?.index() ?? [] }
    }
}
