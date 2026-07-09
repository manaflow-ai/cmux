import CmuxFoundation
import Foundation

/// Discovers `SKILL.md` files under the relevant skill search roots and turns
/// them into `TextBoxMentionCandidate`s for the `/skill` (and `$skill`) mention
/// picker.
///
/// This is a stateless value Service: it owns no cache. The caller
/// (`TextBoxMentionIndexStore`) computes the search roots once via
/// ``searchRoots(rootDirectory:)`` to key its index cache, then asks for the
/// candidates produced from those roots via ``candidates(inRoots:)``. The
/// directory-skip rules, `FileManager`, and the skill cap are constructor
/// injected so the discovery walk is testable in isolation.
struct TextBoxMentionSkillScanner {
    private let fileManager: FileManager
    private let directorySkipPolicy: IndexedDirectorySkipPolicy
    private let maxIndexedSkills: Int

    init(
        fileManager: FileManager = .default,
        directorySkipPolicy: IndexedDirectorySkipPolicy = IndexedDirectorySkipPolicy(),
        maxIndexedSkills: Int = 800
    ) {
        self.fileManager = fileManager
        self.directorySkipPolicy = directorySkipPolicy
        self.maxIndexedSkills = maxIndexedSkills
    }

    /// The ordered, deduplicated list of `skills` directories to scan for the
    /// given project root. Ordering encodes priority (earlier roots win).
    func searchRoots(rootDirectory: String?) -> [URL] {
        var roots: [URL] = []

        if let rootDirectory {
            var current = URL(fileURLWithPath: rootDirectory, isDirectory: true).standardizedFileURL
            while current.path != "/" {
                let skillsURL = current.appendingPathComponent("skills", isDirectory: true)
                if fileManager.fileExists(atPath: skillsURL.path) {
                    roots.append(skillsURL)
                }
                current.deleteLastPathComponent()
            }
        }

        let home = fileManager.homeDirectoryForCurrentUser
        roots.append(home.appendingPathComponent(".codex/skills", isDirectory: true))
        roots.append(home.appendingPathComponent(".codex/skills/.system", isDirectory: true))
        roots.append(home.appendingPathComponent(".agents/skills", isDirectory: true))
        roots.append(contentsOf: pluginSkillRoots(
            pluginCacheURL: home.appendingPathComponent(".codex/plugins/cache", isDirectory: true)
        ))

        var seen = Set<String>()
        return roots
            .map(\.standardizedFileURL)
            .filter { fileManager.fileExists(atPath: $0.path) }
            .filter { seen.insert($0.path).inserted }
    }

    /// Builds the skill candidates discovered under `roots`, deduplicating by
    /// resolved path and capping at `maxIndexedSkills`. The root's index in
    /// `roots` becomes the candidate priority.
    func candidates(inRoots roots: [URL]) -> [TextBoxMentionCandidate] {
        var seenPaths = Set<String>()
        var candidates: [TextBoxMentionCandidate] = []
        for (rootIndex, root) in roots.enumerated() {
            for skillURL in scanSkillFiles(rootURL: root) {
                let path = skillURL.standardizedFileURL.path
                guard seenPaths.insert(path).inserted else { continue }
                let skillName = self.skillName(from: skillURL)
                candidates.append(TextBoxMentionCandidate(
                    title: "/\(skillName)",
                    subtitle: path.homeAbbreviatedPath,
                    targetPath: path,
                    systemImageName: "sparkle.magnifyingglass",
                    searchKey: skillSearchKey(skillName: skillName, skillURL: skillURL, rootURL: root),
                    priority: rootIndex
                ))
                if candidates.count >= maxIndexedSkills {
                    break
                }
            }
            if candidates.count >= maxIndexedSkills {
                break
            }
        }
        return candidates
    }

    private func scanSkillFiles(rootURL: URL) -> [URL] {
        guard fileManager.fileExists(atPath: rootURL.path) else { return [] }

        var result: [URL] = []
        if fileManager.fileExists(atPath: rootURL.appendingPathComponent("SKILL.md").path) {
            result.append(rootURL.appendingPathComponent("SKILL.md"))
            return result
        }

        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return result }

        while let item = enumerator.nextObject() as? URL {
            let standardizedURL = item.standardizedFileURL
            let name = standardizedURL.lastPathComponent
            let values = try? standardizedURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values?.isDirectory == true {
                if directorySkipPolicy.shouldSkip(name) {
                    enumerator.skipDescendants()
                    continue
                }

                let skillFile = standardizedURL.appendingPathComponent("SKILL.md", isDirectory: false)
                if fileManager.fileExists(atPath: skillFile.path) {
                    result.append(skillFile.standardizedFileURL)
                    enumerator.skipDescendants()
                }
            } else if values?.isRegularFile == true, name == "SKILL.md" {
                result.append(standardizedURL)
            }

            if result.count >= maxIndexedSkills {
                break
            }
        }

        return result
    }

    private func pluginSkillRoots(pluginCacheURL: URL) -> [URL] {
        guard let vendors = try? fileManager.contentsOfDirectory(
            at: pluginCacheURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var roots: [URL] = []
        for vendor in vendors where isDirectory(vendor) {
            guard let pluginNames = try? fileManager.contentsOfDirectory(
                at: vendor,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for pluginName in pluginNames where isDirectory(pluginName) {
                guard let versions = try? fileManager.contentsOfDirectory(
                    at: pluginName,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }

                for version in versions where isDirectory(version) {
                    let skillsURL = version.appendingPathComponent("skills", isDirectory: true)
                    if isDirectory(skillsURL) {
                        roots.append(skillsURL)
                    }
                }
            }
        }
        return roots
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func skillName(from skillURL: URL) -> String {
        guard let content = try? String(contentsOf: skillURL, encoding: .utf8) else {
            return skillURL.deletingLastPathComponent().lastPathComponent
        }

        for line in content.split(separator: "\n", maxSplits: 32, omittingEmptySubsequences: false) {
            let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("name:") else { continue }
            let name = String(trimmed.dropFirst("name:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                return name.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        return skillURL.deletingLastPathComponent().lastPathComponent
    }

    private func skillSearchKey(skillName: String, skillURL: URL, rootURL: URL) -> String {
        let skillDirectory = skillURL.deletingLastPathComponent().standardizedFileURL
        let relativeSkillPath = skillDirectory.path.pathRelative(
            toRoot: rootURL.standardizedFileURL.path
        )
        return "\(skillName) \(relativeSkillPath)".lowercased()
    }
}
