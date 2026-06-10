import Darwin
import Foundation


// MARK: - Diff Viewer Source, Repo, and Branch Base Options
extension CMUXCLI {
    func diffViewerSourceOptions(
        selected: DiffSource,
        urls: [DiffSource: URL]
    ) -> [DiffViewerSourceOption] {
        DiffSource.allCases.map { option in
            DiffViewerSourceOption(
                value: option.slug,
                label: option.menuLabel,
                selected: option == selected,
                url: urls[option]?.absoluteString,
                disabled: false,
                message: nil,
                sourceLabel: nil
            )
        }
    }

    func diffViewerRepoOptions(
        selectedRepoRoot: String,
        candidates: [DiffViewerRepoOption],
        urls: [String: URL]
    ) -> [DiffViewerSourceOption] {
        guard candidates.count > 1 else { return [] }
        return candidates.map { option in
            DiffViewerSourceOption(
                value: option.repoRoot,
                label: option.label,
                selected: option.repoRoot == selectedRepoRoot,
                url: urls[option.repoRoot]?.absoluteString,
                disabled: false,
                message: option.repoRoot,
                sourceLabel: nil
            )
        }
    }

    func diffViewerBranchBaseOptions(
        selectedBaseRef: String?,
        candidates: [DiffViewerBranchBaseOption],
        urls: [String: URL]
    ) -> [DiffViewerSourceOption] {
        guard candidates.count > 1 else { return [] }
        return candidates.map { option in
            DiffViewerSourceOption(
                value: option.ref,
                label: option.label,
                selected: selectedBaseRef.map { $0 == option.ref } ?? false,
                url: urls[option.ref]?.absoluteString,
                disabled: false,
                message: option.ref,
                sourceLabel: nil
            )
        }
    }

    func gitDiffViewerRepoOptions(selectedRepoRoot: String) -> [DiffViewerRepoOption] {
        let selectedURL = URL(fileURLWithPath: selectedRepoRoot, isDirectory: true).standardizedFileURL
        var candidateURLs: [URL] = [selectedURL]
        let parentURL = selectedURL.deletingLastPathComponent()

        if parentURL.lastPathComponent == "worktrees" {
            let hqURL = parentURL.deletingLastPathComponent()
            let primaryRepoURL = hqURL.appendingPathComponent("repo", isDirectory: true)
            if diffViewerDirectoryContainsGitMetadata(primaryRepoURL) {
                candidateURLs.append(primaryRepoURL)
            }
        }

        candidateURLs.append(contentsOf: gitChildRepoURLs(in: parentURL))

        if selectedURL.lastPathComponent == "repo" {
            let worktreesURL = parentURL.appendingPathComponent("worktrees", isDirectory: true)
            candidateURLs.append(contentsOf: gitChildRepoURLs(in: worktreesURL))
        }

        var seen: Set<String> = []
        var roots: [String] = []
        for candidateURL in candidateURLs {
            guard roots.count < DiffViewerLimits.repoOptions,
                  let root = try? gitRepoRoot(startingAt: candidateURL.path),
                  !seen.contains(root) else {
                continue
            }
            seen.insert(root)
            roots.append(root)
        }

        if !seen.contains(selectedRepoRoot) {
            roots.insert(selectedRepoRoot, at: 0)
        }

        return roots.map { root in
            DiffViewerRepoOption(
                repoRoot: root,
                label: gitDiffViewerRepoLabel(root, selectedRepoRoot: selectedRepoRoot)
            )
        }
    }

    private func gitChildRepoURLs(in directoryURL: URL) -> [URL] {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }
        return children
            .filter { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true &&
                    diffViewerDirectoryContainsGitMetadata(url)
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func diffViewerDirectoryContainsGitMetadata(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(".git", isDirectory: false).path)
    }

    private func gitDiffViewerRepoLabel(_ repoRoot: String, selectedRepoRoot: String) -> String {
        let repoURL = URL(fileURLWithPath: repoRoot, isDirectory: true).standardizedFileURL
        let selectedURL = URL(fileURLWithPath: selectedRepoRoot, isDirectory: true).standardizedFileURL
        let selectedParent = selectedURL.deletingLastPathComponent()
        let selectedGrandparent = selectedParent.deletingLastPathComponent()
        if selectedParent.lastPathComponent == "worktrees",
           repoURL.deletingLastPathComponent() == selectedParent {
            return "worktrees/\(repoURL.lastPathComponent)"
        }
        if repoURL.deletingLastPathComponent() == selectedGrandparent,
           repoURL.lastPathComponent == "repo" {
            return "repo"
        }
        if repoURL.deletingLastPathComponent() == selectedParent {
            let name = repoURL.lastPathComponent
            return name.isEmpty ? repoRoot : name
        }
        return repoRoot
    }

    func gitDiffViewerBranchBaseOptions(
        in repoRoot: String,
        selectedBaseRef: String?
    ) -> [DiffViewerBranchBaseOption] {
        var refs: [String] = []
        func appendRef(_ ref: String?) {
            guard let ref = ref?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !ref.isEmpty,
                  !refs.contains(ref),
                  !ref.hasSuffix("/HEAD") else {
                return
            }
            refs.append(ref)
        }

        appendRef(selectedBaseRef)
        appendRef(try? gitBranchDiffBaseRef(in: repoRoot))
        if let listing = try? gitStdout(
            ["for-each-ref", "--format=%(refname:short)", "refs/remotes", "refs/heads"],
            in: repoRoot
        ) {
            for line in listing.split(whereSeparator: \.isNewline).map(String.init) where refs.count < DiffViewerLimits.branchBaseOptions {
                appendRef(line)
            }
        }

        return refs.map { ref in
            DiffViewerBranchBaseOption(ref: ref, label: ref)
        }
    }

}
