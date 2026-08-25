import Dispatch
import Foundation

extension SystemGitReferenceReader {
    enum QuickReferenceStorageProbe: Sendable {
        case complete(String?)
        case incomplete
    }

    /// Reads the root config prefix without trusting an incomplete include graph.
    func quickReferenceStorageName(
        repository: ResolvedGitRepository,
        deadline: DispatchTime?
    ) -> QuickReferenceStorageProbe {
        var storageName: String?
        var hasInclude = false
        for configURL in GitMetadataService.gitRootConfigURLs(repository: repository) {
            if let deadline, deadline <= DispatchTime.now() { return .incomplete }
            switch configReader.read(
                at: configURL,
                maximumByteCount: 64 * 1_024,
                deadline: deadline
            ) {
            case .missing:
                continue
            case .oversized, .unavailable:
                return .incomplete
            case .contents(let contents, consumedByteCount: _):
                var inExtensionsSection = false
                var inIncludeSection = false
                for rawLine in contents.split(whereSeparator: \.isNewline) {
                    if let deadline, deadline <= DispatchTime.now() { return .incomplete }
                    let line = GitMetadataService.gitConfigLineRemovingInlineComment(String(rawLine))
                        .trimmingCharacters(in: .whitespaces)
                    if line.hasPrefix("[") && line.hasSuffix("]") {
                        let lowercased = line.lowercased()
                        inExtensionsSection = lowercased == "[extensions]"
                        inIncludeSection = lowercased == "[include]"
                            || lowercased.hasPrefix("[includeif ")
                        continue
                    }
                    let parts = line.split(separator: "=", maxSplits: 1).map {
                        $0.trimmingCharacters(in: .whitespaces)
                    }
                    guard parts.count == 2 else { continue }
                    if inIncludeSection, parts[0].lowercased() == "path" {
                        hasInclude = true
                    }
                    if inExtensionsSection, parts[0].lowercased() == "refstorage" {
                        storageName = GitMetadataService.gitConfigUnquotedValue(parts[1]).lowercased()
                    }
                }
            }
        }
        return hasInclude ? .incomplete : .complete(storageName)
    }

    func unreadableSnapshot() -> GitReferenceSnapshot {
        GitReferenceSnapshot(checkedOutBranch: .unreadable, headSignature: nil, currentCommit: nil)
    }

    /// Resolves the configured backend through the bounded include traversal.
    func referenceStorageName(
        repository: ResolvedGitRepository,
        branchContext: GitConfigBranchContext,
        deadline: DispatchTime? = nil
    ) -> String? {
        GitConfigBranchTraversal(
            repository: repository,
            branchContext: branchContext,
            configReader: configReader,
            deadline: deadline
        ).referenceStorageName()
    }

}
