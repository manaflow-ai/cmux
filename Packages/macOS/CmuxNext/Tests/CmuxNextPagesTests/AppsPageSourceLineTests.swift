import CmuxNextPages
import CmuxNextSettings
import Testing

/// An app installed from a git reference: the consent card says where it comes from, at which
/// commit (and tag), whether that commit is a verified source, and when the cmux registry has not
/// reviewed the repository. An App Store app's card has no such line.
struct AppsPageSourceLineTests {
    private static let commit = "0123456789abcdef0123456789abcdef01234567"

    private func detail(_ extra: [String: JSONValue] = [:]) -> JSONValue {
        var fields: [String: JSONValue] = ["name": "Standup", "scopes": [],
                                           "repository": "https://github.com/o/r", "commit": .string(Self.commit)]
        fields.merge(extra) { $1 }
        return .object(fields)
    }

    private func line(_ op: String, _ detail: JSONValue) -> String? {
        AppsPageConfirmations().confirmation(op: op, params: ["app": "github.com/o/r"], detail: detail)?.detail
    }

    @Test func installAndUpdateNameTheRepositoryAndShortCommit() {
        #expect(line("cmux.apps.install", detail()) == "From github.com/o/r at 0123456.")
        #expect(line("cmux.apps.update", detail()) == "From github.com/o/r at 0123456.")
    }

    @Test func aPathATagAndTheReviewAndVerificationStatesShowOnTheOneLine() {
        #expect(line("cmux.apps.install", detail(["path": "apps/standup"])) == "From github.com/o/r/apps/standup at 0123456.")
        #expect(line("cmux.apps.install", detail(["tag": "v1.2.0"])) == "From github.com/o/r at v1.2.0 (0123456).")
        #expect(line("cmux.apps.install", detail(["reviewed": false])) == "From github.com/o/r at 0123456. Not reviewed by cmux.")
        #expect(line("cmux.apps.install", detail(["reviewed": true])) == "From github.com/o/r at 0123456.")
        #expect(line("cmux.apps.install", detail(["verified_source": true, "reviewed": false]))
            == "From github.com/o/r at 0123456. Verified source. Not reviewed by cmux.")
    }

    @Test func anAppStoreAppOrAnotherOpHasNoSourceLine() {
        #expect(line("cmux.apps.install", ["name": "Standup", "scopes": []]) == nil)
        #expect(line("cmux.apps.install", ["name": "Standup", "repository": "https://github.com/o/r"]) == nil)
        #expect(line("cmux.apps.uninstall", detail()) == nil)
    }
}
