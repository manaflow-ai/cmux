@testable import CmuxCloud
import Foundation
import Testing

/// Git remote normalization into project scope keys.
@Suite struct CloudSecretProjectKeyTests {
    @Test(arguments: [
        ("https://github.com/manaflow-ai/cmux.git", "github.com/manaflow-ai/cmux"),
        ("https://github.com/manaflow-ai/cmux", "github.com/manaflow-ai/cmux"),
        ("https://github.com/Manaflow-AI/CMUX.git", "github.com/manaflow-ai/cmux"),
        ("HTTPS://GitHub.com/owner/repo/", "github.com/owner/repo"),
        ("http://github.com/owner/repo.git", "github.com/owner/repo"),
        ("https://x-access-token:abc@github.com/owner/repo.git", "github.com/owner/repo"),
        ("https://github.com:443/owner/repo", "github.com/owner/repo"),
        ("git@github.com:manaflow-ai/cmux.git", "github.com/manaflow-ai/cmux"),
        ("git@github.com:manaflow-ai/cmux", "github.com/manaflow-ai/cmux"),
        ("git@GitHub.com:Owner/Repo.git", "github.com/owner/repo"),
        ("github.com:owner/repo.git", "github.com/owner/repo"),
        ("ssh://git@github.com/owner/repo.git", "github.com/owner/repo"),
        ("ssh://git@github.com:22/owner/repo.git", "github.com/owner/repo"),
        ("git://github.com/owner/repo.git", "github.com/owner/repo"),
        ("  https://github.com/owner/repo.git\n", "github.com/owner/repo"),
        ("https://gitlab.com/group/subgroup/repo.git", "gitlab.com/group/subgroup/repo"),
        ("git@gitlab.example.com:group/sub/repo.git", "gitlab.example.com/group/sub/repo")
    ])
    func normalizesRemoteForms(remote: String, expected: String) {
        #expect(CloudSecretProjectKey.normalize(remoteURL: remote) == expected)
    }

    @Test(arguments: [
        "",
        "   ",
        "/Users/me/src/repo",
        "../repo",
        "./repo.git",
        "file:///Users/me/repo.git",
        "https://github.com",
        "https://github.com/",
        "https://github.com/.git",
        "git@github.com:",
        "not a remote"
    ])
    func refusesLocalOrIncompleteRemotes(remote: String) {
        #expect(CloudSecretProjectKey.normalize(remoteURL: remote) == nil)
    }

    @Test
    func fallbackUsesLocalPrefix() {
        #expect(CloudSecretProjectKey.fallback(directoryName: "my-app") == "local/my-app")
    }

    @Test
    func normalizedKeysAreValidProjectScopes() throws {
        let key = try #require(CloudSecretProjectKey.normalize(remoteURL: "git@github.com:o/r.git"))
        let scope = CloudSecretScope.project(key)
        #expect(CloudSecretScope(wireValue: scope.wireValue) == scope)
    }
}
