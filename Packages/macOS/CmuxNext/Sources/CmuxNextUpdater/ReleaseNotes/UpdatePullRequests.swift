public import Foundation

/// "What's in this build": the pull requests merged since the build the person has, across every
/// nightly the update skips, grouped by area (Leo 2026-11-26: "hm do we display which prs go into
/// which nightly maybe that'd be useful per thing?"). The update-ready popover and Settings > Updates'
/// App Update card draw it; both only render this value.
nonisolated public struct UpdatePullRequests: Codable, Equatable, Sendable {
    /// The area a change without one is filed under.
    public static let otherArea = "other"
    /// The most builds one list reads: an install months old does not fetch hundreds of notes.
    public static let spanLimit = 40

    public struct Entry: Codable, Equatable, Sendable {
        public var pr: Int?
        public var title: String
        public var author: String?
        /// The PR's page: the notes' `url`, else the manaflow-ai/cmux pull page.
        public var url: URL?
        /// The build that brought it.
        public var build: String

        public init(pr: Int?, title: String, author: String?, url: URL?, build: String) {
            self.pr = pr
            self.title = title
            self.author = author
            self.url = url
            self.build = build
        }
    }

    public struct Group: Codable, Equatable, Sendable {
        /// The notes' area key (lowercased), or ``UpdatePullRequests/otherArea``.
        public var area: String
        public var items: [Entry]
    }

    /// Largest area first, Other last.
    public var groups: [Group]
    /// The builds the list spans, newest first.
    public var builds: [String]

    public var count: Int { groups.reduce(0) { $0 + $1.items.count } }
    public var isEmpty: Bool { groups.isEmpty }

    /// The PRs of `notes` (any order): each PR once (its newest build's row), internal-only changes
    /// left out, every change without a PR number left out (a commit, not a PR).
    public init(notes: [ReleaseNotes]) {
        let ordered = notes.sorted { Self.isNewer($0.build, than: $1.build) }
        var seen = Set<Int>()
        var byArea: [String: [Entry]] = [:]
        var order: [String] = []
        for build in ordered {
            for item in build.changeItems where item.isInternal != true {
                guard let pr = item.pr, seen.insert(pr).inserted else { continue }
                let area = item.area?.lowercased() ?? Self.otherArea
                if byArea[area] == nil { order.append(area) }
                byArea[area, default: []].append(Entry(pr: pr, title: item.title, author: item.author, url: item.url, build: build.build))
            }
        }
        groups = order.map { Group(area: $0, items: byArea[$0] ?? []) }.enumerated().sorted { lhs, rhs in
            let (l, r) = (lhs.element, rhs.element)
            if (l.area == Self.otherArea) != (r.area == Self.otherArea) { return r.area == Self.otherArea }
            if l.items.count != r.items.count { return l.items.count > r.items.count }
            return lhs.offset < rhs.offset
        }.map(\.element)
        builds = ordered.map(\.build)
    }

    /// The builds an update from `installed` to `offered` brings: every build of `index` newer than
    /// `installed`, up to and including `offered`, newest first, at most ``spanLimit``. `offered` alone when the index
    /// lacks it or a build number is not a number.
    public static func span(index: [ReleaseNotesIndexEntry], installed: String, offered: String) -> [String] {
        guard Int(installed) != nil, Int(offered) != nil else { return [offered] }
        var builds = index.map(\.build).filter { isNewer($0, than: installed) && !isNewer($0, than: offered) }
        if !builds.contains(offered) { builds.append(offered) }
        return Array(builds.sorted { isNewer($0, than: $1) }.prefix(spanLimit))
    }

    /// Build numbers compare as numbers ("1000" is newer than "999"); otherwise as text.
    static func isNewer(_ build: String, than other: String) -> Bool {
        if let lhs = Int(build), let rhs = Int(other) { return lhs > rhs }
        return build > other
    }
}
