import Foundation
import SwiftUI
import AppKit
import Bonsplit
import CMUXAgentLaunch
import CmuxSocketControl
import Combine
import CryptoKit
import Darwin
import Network
import CoreText


enum SidebarBranchOrdering {
    struct BranchEntry: Equatable {
        let name: String
        let isDirty: Bool
    }

    struct BranchDirectoryEntry: Equatable {
        let branch: String?
        let isDirty: Bool
        let directory: String?
    }

    fileprivate static func normalizedDirectory(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func relativePathFromTilde(_ directory: String) -> String? {
        let normalized = normalizedDirectory(directory)
        switch normalized {
        case "~":
            return ""
        case let path? where path.hasPrefix("~/"):
            return String(path.dropFirst(2))
        default:
            return nil
        }
    }

    private static func commonHomeDirectoryPrefix(from absoluteDirectory: String) -> String? {
        guard let normalized = normalizedDirectory(absoluteDirectory) else { return nil }
        let standardized = NSString(string: normalized).standardizingPath
        if standardized == "/root" || standardized.hasPrefix("/root/") {
            return "/root"
        }

        let components = NSString(string: standardized).pathComponents
        if components.count >= 3, components[0] == "/", components[1] == "Users" {
            return NSString.path(withComponents: Array(components.prefix(3)))
        }
        if components.count >= 3, components[0] == "/", components[1] == "home" {
            return NSString.path(withComponents: Array(components.prefix(3)))
        }
        if components.count >= 4, components[0] == "/", components[1] == "var", components[2] == "home" {
            return NSString.path(withComponents: Array(components.prefix(4)))
        }

        return nil
    }

    private static func inferredHomeDirectory(
        matchingTildeDirectory tildeDirectory: String,
        absoluteDirectory: String
    ) -> String? {
        guard let relativePath = relativePathFromTilde(tildeDirectory),
              let normalizedAbsolute = normalizedDirectory(absoluteDirectory) else { return nil }
        let standardizedAbsolute = NSString(string: normalizedAbsolute).standardizingPath
        let homeDirectory: String
        if relativePath.isEmpty {
            homeDirectory = standardizedAbsolute
        } else {
            let suffix = "/" + relativePath
            guard standardizedAbsolute.hasSuffix(suffix) else { return nil }
            homeDirectory = String(standardizedAbsolute.dropLast(suffix.count))
        }

        guard commonHomeDirectoryPrefix(from: homeDirectory) == homeDirectory else { return nil }
        return homeDirectory
    }

    static func inferredRemoteHomeDirectory(
        from directories: [String],
        fallbackDirectory: String?
    ) -> String? {
        let candidates = directories + [fallbackDirectory].compactMap { $0 }
        let tildeDirectories = candidates.compactMap { directory -> String? in
            guard let normalized = normalizedDirectory(directory),
                  relativePathFromTilde(normalized) != nil else { return nil }
            return normalized
        }
        let absoluteDirectories = candidates.compactMap { directory -> String? in
            guard let normalized = normalizedDirectory(directory), normalized.hasPrefix("/") else { return nil }
            return NSString(string: normalized).standardizingPath
        }

        let inferredHomes = Set(
            tildeDirectories.flatMap { tildeDirectory in
                absoluteDirectories.compactMap { absoluteDirectory in
                    inferredHomeDirectory(
                        matchingTildeDirectory: tildeDirectory,
                        absoluteDirectory: absoluteDirectory
                    )
                }
            }
        )

        if inferredHomes.count == 1 {
            return inferredHomes.first
        }
        if !inferredHomes.isEmpty {
            return nil
        }

        return absoluteDirectories.lazy.compactMap(commonHomeDirectoryPrefix(from:)).first
    }

    private static func expandedTildePath(
        _ directory: String,
        homeDirectoryForTildeExpansion: String?
    ) -> String {
        guard let relativePath = relativePathFromTilde(directory),
              let homeDirectory = normalizedDirectory(homeDirectoryForTildeExpansion) else {
            return directory
        }
        if relativePath.isEmpty {
            return homeDirectory
        }
        return NSString(string: homeDirectory).appendingPathComponent(relativePath)
    }

    static func canonicalDirectoryKey(
        _ directory: String?,
        homeDirectoryForTildeExpansion: String?
    ) -> String? {
        guard let directory = normalizedDirectory(directory) else { return nil }
        let expanded = expandedTildePath(
            directory,
            homeDirectoryForTildeExpansion: homeDirectoryForTildeExpansion
        )
        let standardized = NSString(string: expanded).standardizingPath
        let cleaned = standardized.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func preferredDisplayedDirectory(
        existing: String?,
        replacement: String?,
        homeDirectoryForTildeExpansion: String?
    ) -> String? {
        guard let replacement = normalizedDirectory(replacement) else { return existing }
        guard let existing = normalizedDirectory(existing) else { return replacement }

        let existingUsesTilde = relativePathFromTilde(existing) != nil
        let replacementUsesTilde = relativePathFromTilde(replacement) != nil
        if existingUsesTilde != replacementUsesTilde {
            return replacementUsesTilde ? existing : replacement
        }

        if canonicalDirectoryKey(existing, homeDirectoryForTildeExpansion: homeDirectoryForTildeExpansion)
            == canonicalDirectoryKey(
                replacement,
                homeDirectoryForTildeExpansion: homeDirectoryForTildeExpansion
            ) {
            return existing
        }

        return replacement
    }

    static func orderedPaneIds(tree: ExternalTreeNode) -> [String] {
        switch tree {
        case .pane(let pane):
            return [pane.id]
        case .split(let split):
            // Bonsplit split order matches visual order for both horizontal and vertical splits.
            return orderedPaneIds(tree: split.first) + orderedPaneIds(tree: split.second)
        }
    }

    static func orderedPanelIds(
        tree: ExternalTreeNode,
        paneTabs: [String: [UUID]],
        fallbackPanelIds: [UUID]
    ) -> [UUID] {
        var ordered: [UUID] = []
        var seen: Set<UUID> = []

        for paneId in orderedPaneIds(tree: tree) {
            for panelId in paneTabs[paneId] ?? [] {
                if seen.insert(panelId).inserted {
                    ordered.append(panelId)
                }
            }
        }

        for panelId in fallbackPanelIds {
            if seen.insert(panelId).inserted {
                ordered.append(panelId)
            }
        }

        return ordered
    }

    static func orderedUniqueBranches(
        orderedPanelIds: [UUID],
        panelBranches: [UUID: SidebarGitBranchState],
        fallbackBranch: SidebarGitBranchState?
    ) -> [BranchEntry] {
        var orderedNames: [String] = []
        var branchDirty: [String: Bool] = [:]

        for panelId in orderedPanelIds {
            guard let state = panelBranches[panelId] else { continue }
            let name = state.branch.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }

            if branchDirty[name] == nil {
                orderedNames.append(name)
                branchDirty[name] = state.isDirty
            } else if state.isDirty {
                branchDirty[name] = true
            }
        }

        if orderedNames.isEmpty, let fallbackBranch {
            let name = fallbackBranch.branch.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                return [BranchEntry(name: name, isDirty: fallbackBranch.isDirty)]
            }
        }

        return orderedNames.map { name in
            BranchEntry(name: name, isDirty: branchDirty[name] ?? false)
        }
    }

    static func orderedUniquePullRequests(
        orderedPanelIds: [UUID],
        panelPullRequests: [UUID: SidebarPullRequestState],
        fallbackPullRequest: SidebarPullRequestState?
    ) -> [SidebarPullRequestState] {
        func statusPriority(_ status: SidebarPullRequestStatus) -> Int {
            switch status {
            case .merged: return 3
            case .open: return 2
            case .closed: return 1
            }
        }

        func freshnessPriority(_ isStale: Bool) -> Int {
            isStale ? 0 : 1
        }

        func normalizedReviewURLKey(for url: URL) -> String {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                return url.absoluteString
            }

            // Treat URL variants that differ only by query/fragment as the same review item.
            components.query = nil
            components.fragment = nil
            let scheme = components.scheme?.lowercased() ?? ""
            let host = components.host?.lowercased() ?? ""
            let port = components.port.map { ":\($0)" } ?? ""
            var path = components.path
            if path.hasSuffix("/"), path.count > 1 {
                path.removeLast()
            }
            return "\(scheme)://\(host)\(port)\(path)"
        }

        func reviewKey(for state: SidebarPullRequestState) -> String {
            "\(state.label.lowercased())#\(state.number)|\(normalizedReviewURLKey(for: state.url))"
        }

        var orderedKeys: [String] = []
        var pullRequestsByKey: [String: SidebarPullRequestState] = [:]

        for panelId in orderedPanelIds {
            guard let state = panelPullRequests[panelId] else { continue }
            let key = reviewKey(for: state)
            if pullRequestsByKey[key] == nil {
                orderedKeys.append(key)
                pullRequestsByKey[key] = state
                continue
            }
            guard let existing = pullRequestsByKey[key] else { continue }
            if freshnessPriority(state.isStale) > freshnessPriority(existing.isStale) {
                pullRequestsByKey[key] = state
            } else if freshnessPriority(state.isStale) == freshnessPriority(existing.isStale),
                      statusPriority(state.status) > statusPriority(existing.status) {
                pullRequestsByKey[key] = state
            }
        }

        if orderedKeys.isEmpty, let fallbackPullRequest {
            return [fallbackPullRequest]
        }

        return orderedKeys.compactMap { pullRequestsByKey[$0] }
    }

    static func orderedUniqueBranchDirectoryEntries(
        orderedPanelIds: [UUID],
        panelBranches: [UUID: SidebarGitBranchState],
        panelDirectories: [UUID: String],
        defaultDirectory: String?,
        homeDirectoryForTildeExpansion: String?,
        fallbackBranch: SidebarGitBranchState?
    ) -> [BranchDirectoryEntry] {
        struct EntryKey: Hashable {
            let directory: String?
            let branch: String?
        }

        struct MutableEntry {
            var branch: String?
            var isDirty: Bool
            var directory: String?
        }

        let normalized = normalizedDirectory
        let normalizedFallbackBranch = normalized(fallbackBranch?.branch)
        let shouldUseFallbackBranchPerPanel = !orderedPanelIds.contains {
            normalized(panelBranches[$0]?.branch) != nil
        }
        let defaultBranchForPanels = shouldUseFallbackBranchPerPanel ? normalizedFallbackBranch : nil
        let defaultBranchDirty = shouldUseFallbackBranchPerPanel ? (fallbackBranch?.isDirty ?? false) : false

        var order: [EntryKey] = []
        var entries: [EntryKey: MutableEntry] = [:]

        for panelId in orderedPanelIds {
            let panelBranch = normalized(panelBranches[panelId]?.branch)
            let branch = panelBranch ?? defaultBranchForPanels
            let directory = normalized(panelDirectories[panelId])
            guard branch != nil || directory != nil else { continue }

            let panelDirty = panelBranch != nil
                ? (panelBranches[panelId]?.isDirty ?? false)
                : defaultBranchDirty

            let key: EntryKey
            if let directoryKey = canonicalDirectoryKey(
                directory,
                homeDirectoryForTildeExpansion: homeDirectoryForTildeExpansion
            ) {
                // Keep one line per directory and allow the latest branch state to overwrite.
                key = EntryKey(directory: directoryKey, branch: nil)
            } else {
                key = EntryKey(directory: nil, branch: branch)
            }

            guard key.directory != nil || key.branch != nil else { continue }

            if var existing = entries[key] {
                if key.directory != nil {
                    if let branch {
                        existing.branch = branch
                        existing.isDirty = panelDirty
                    } else if existing.branch == nil {
                        existing.isDirty = panelDirty
                    }
                    existing.directory = preferredDisplayedDirectory(
                        existing: existing.directory,
                        replacement: directory,
                        homeDirectoryForTildeExpansion: homeDirectoryForTildeExpansion
                    )
                    entries[key] = existing
                } else if panelDirty {
                    existing.isDirty = true
                    entries[key] = existing
                }
            } else {
                order.append(key)
                entries[key] = MutableEntry(branch: branch, isDirty: panelDirty, directory: directory)
            }
        }

        if order.isEmpty {
            let fallbackDirectory = normalized(defaultDirectory)
            if normalizedFallbackBranch != nil || fallbackDirectory != nil {
                return [
                    BranchDirectoryEntry(
                        branch: normalizedFallbackBranch,
                        isDirty: fallbackBranch?.isDirty ?? false,
                        directory: fallbackDirectory
                    )
                ]
            }
        }

        return order.compactMap { key in
            guard let entry = entries[key] else { return nil }
            return BranchDirectoryEntry(
                branch: entry.branch,
                isDirty: entry.isDirty,
                directory: entry.directory
            )
        }
    }
}

