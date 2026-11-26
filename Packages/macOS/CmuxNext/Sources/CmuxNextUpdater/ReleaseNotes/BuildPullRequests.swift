public import Foundation

/// "What's in this build": the pull requests merged after the build this Mac runs, up to the
/// offered (or running) one, grouped by area (Leo 2026-11-26: "hm do we display which prs go into
/// which nightly maybe that'd be useful per thing?"). Each build's notes list the changes since the
/// previous build that published notes, so a span is the union of every build's notes in it.
nonisolated public struct BuildPullRequests: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable {
        public var pr: Int
        public var title: String
        public var author: String?
        public var url: URL
        /// The build whose notes list it (the newest one when several do).
        public var build: String
    }

    public struct Group: Codable, Equatable, Sendable {
        /// The area's name; nil is "Other" (notes without an area).
        public var area: String?
        public var items: [Item]
    }

    /// Areas in the order their first (newest) PR appears; "Other" last.
    public var groups: [Group]
    /// Internal (CI or tooling only) PRs, counted and not listed.
    public var internalCount: Int

    public var count: Int { groups.reduce(0) { $0 + $1.items.count } }
    public var isEmpty: Bool { groups.isEmpty }

    /// The builds a span covers, newest first: every indexed build after `installed` through
    /// `offered`, compared as build numbers. Names that are not build numbers are left out.
    public static func builds(in index: [ReleaseNotesIndexEntry], after installed: String, through offered: String) -> [String] {
        index.map(\.build)
            .filter { ReleaseNotesStore.isSafeName($0) }
            .filter { InstalledBuildWatch.isNewer($0, than: installed) && !InstalledBuildWatch.isNewer($0, than: offered) }
            .sorted { InstalledBuildWatch.isNewer($0, than: $1) }
    }

    /// The span's pull requests from its builds' notes (any order): newest build first, one row
    /// per PR (the newest notes' wording wins), internal PRs counted, commits without a PR left out.
    public init(notes: [ReleaseNotes]) {
        var seen = Set<Int>()
        var internalCount = 0
        var areas: [String] = []
        var byArea: [String: [Item]] = [:]
        var other: [Item] = []
        let newestFirst = notes.sorted { InstalledBuildWatch.isNewer($0.build, than: $1.build) }
        for build in newestFirst {
            for change in build.changeItems {
                guard let pr = change.pr, let url = change.url, seen.insert(pr).inserted else { continue }
                if change.isInternal == true {
                    internalCount += 1
                    continue
                }
                let item = Item(pr: pr, title: change.title, author: change.author, url: url, build: build.build)
                let area = change.area?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if area.isEmpty {
                    other.append(item)
                } else {
                    if byArea[area] == nil { areas.append(area) }
                    byArea[area, default: []].append(item)
                }
            }
        }
        var groups = areas.map { Group(area: $0, items: byArea[$0] ?? []) }
        if !other.isEmpty { groups.append(Group(area: nil, items: other)) }
        self.groups = groups
        self.internalCount = internalCount
    }

    public init(groups: [Group], internalCount: Int = 0) {
        self.groups = groups
        self.internalCount = internalCount
    }
}
