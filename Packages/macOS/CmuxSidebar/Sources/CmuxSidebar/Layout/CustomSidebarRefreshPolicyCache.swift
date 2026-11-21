public import Foundation

/// Answers ``CustomSidebarRefreshPolicy`` for a sidebar file, re-reading the
/// file only when its modification date changes.
///
/// The loaded file is resolved by name and may switch between `.swift`,
/// `.json` and `.js` across reloads, so every candidate with the same base
/// name is checked. A lookup is reused for ``recheckInterval``; after that
/// the candidates are stat'ed again, and their contents are read only when
/// one changed.
///
/// A candidate that exists but can't be read answers
/// ``CustomSidebarRefreshPolicy/everySecond`` and isn't cached, so a
/// transient read failure can't freeze a `clock` sidebar.
public final class CustomSidebarRefreshPolicyCache {
    /// One candidate's resolved file (its symlink target) and modification
    /// date; `nil` date when the candidate doesn't exist.
    private struct CandidateState: Equatable {
        let resolvedPath: String
        let modificationDate: Date?
    }

    private struct Entry {
        let candidateStates: [CandidateState]
        let policy: CustomSidebarRefreshPolicy
        var checkedAt: Date
    }

    /// How long an answer is reused before the files are stat'ed again.
    /// Lookups happen on every re-render; an edit that adds or removes
    /// `clock` only needs to switch the tick within a few seconds.
    public static let recheckInterval: TimeInterval = 2

    static let candidateExtensions = ["swift", "json", "js"]

    private var entries: [URL: Entry] = [:]
    private let fileManager: FileManager
    private let readSource: (URL) -> String?

    /// Creates a cache.
    ///
    /// - Parameters:
    ///   - fileManager: Reads candidate modification dates.
    ///   - readSource: Reads a candidate's text, or `nil` when it can't be
    ///     read; injectable for tests.
    public init(
        fileManager: FileManager = .default,
        readSource: @escaping (URL) -> String? = { try? String(contentsOf: $0, encoding: .utf8) }
    ) {
        self.fileManager = fileManager
        self.readSource = readSource
    }

    /// The policy for the sidebar at `fileURL`, or for `sourceOverride`
    /// (an in-memory preview) when given.
    public func policy(
        fileURL: URL,
        sourceOverride: String? = nil,
        now: Date = Date()
    ) -> CustomSidebarRefreshPolicy {
        if let sourceOverride {
            return CustomSidebarRefreshPolicy.policy(forSource: sourceOverride)
        }
        let base = fileURL.deletingPathExtension()
        if let entry = entries[base], now.timeIntervalSince(entry.checkedAt) < Self.recheckInterval {
            return entry.policy
        }
        let candidates = Self.candidateExtensions.map { base.appendingPathExtension($0) }
        // Stat the symlink target, not the link: a dotfiles-managed sidebar
        // is often a symlink, and editing its target leaves the link's own
        // date unchanged. The target's path is part of the state, so
        // pointing the link at another file is noticed even when both files
        // share a modification date.
        let states = candidates.map { url in
            let resolvedPath = url.resolvingSymlinksInPath().path
            return CandidateState(
                resolvedPath: resolvedPath,
                modificationDate: (try? fileManager.attributesOfItem(atPath: resolvedPath)[.modificationDate]) as? Date
            )
        }
        if var entry = entries[base], entry.candidateStates == states {
            entry.checkedAt = now
            entries[base] = entry
            return entry.policy
        }
        var sources: [String] = []
        for (url, state) in zip(candidates, states) where state.modificationDate != nil {
            guard let source = readSource(url) else {
                entries[base] = nil
                return .everySecond
            }
            sources.append(source)
        }
        let policy = CustomSidebarRefreshPolicy.policy(forSources: sources)
        entries[base] = Entry(candidateStates: states, policy: policy, checkedAt: now)
        return policy
    }
}
