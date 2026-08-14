import Foundation
@testable import CmuxGit

struct FakeGitMetadataGitRunner: GitMetadataGitRunning {
    let responses: [[String]: GitMetadataGitResult]

    func run(arguments: [String], in directory: URL) -> GitMetadataGitResult {
        responses[arguments] ?? GitMetadataGitResult(output: "", exitCode: 127)
    }
}
