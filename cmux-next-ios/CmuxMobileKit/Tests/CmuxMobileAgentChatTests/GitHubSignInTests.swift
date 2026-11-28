import Foundation
import Testing
@testable import CmuxMobileAgentChat

/// Sign in with GitHub on the phone (Leo, 2026-11-25: "You need to just do this and wire it up"):
/// a Cloud start's `seed.needs_github` and a chat's refused GitHub call each become one card with
/// one Sign in with GitHub, keyed on the shapes the Mac's `githubConnect.ts` reads.
@MainActor
@Suite struct GitHubSignInTests {
    // MARK: A Cloud start

    @Test func aStartRefusedForGitHubNamesTheRepository() throws {
        let details: JSONValue = .object(["repo": .string("acme/web"), "githubLogin": .string("none")])
        let need = try #require(GitHubSignInNeed(startCode: "seed.needs_github", details: details))
        #expect(need.repo == "acme/web")
        #expect(need.reason == .clone(login: GitHubSignInNeed.Login.none, user: nil))
        #expect(need.line == "Sign in with GitHub so Cloud can clone acme/web.")
        #expect(GitHubSignInNeed(startCode: "seed.clone_failed", details: details) == nil)
        #expect(GitHubSignInNeed(startCode: nil, details: details) == nil)
    }

    @Test func aCarriedLoginWithNoAccessToTheRepositoryIsNamed() throws {
        let details: JSONValue = .object(["repo": .string("acme/web"), "githubLogin": .string("carried"), "githubUser": .string("octo")])
        let need = try #require(GitHubSignInNeed(startCode: "seed.needs_github", details: details))
        #expect(need.line == "GitHub account octo doesn't have access to acme/web. Sign in with GitHub to give Cloud access.")
        // A login that was not carried, or a user name GitHub would not allow, is not named.
        let notCarried: JSONValue = .object(["repo": .string("acme/web"), "githubLogin": .string("not_carried"), "githubUser": .string("octo")])
        #expect(try #require(GitHubSignInNeed(startCode: "seed.needs_github", details: notCarried)).line
            == "Sign in with GitHub so Cloud can clone acme/web.")
        let odd: JSONValue = .object(["githubLogin": .string("carried"), "githubUser": .string("a b")])
        #expect(try #require(GitHubSignInNeed(startCode: "seed.needs_github", details: odd)).line
            == "Sign in with GitHub so Cloud can clone this repository.")
    }

    @Test func aStartWithNoDetailsTakesItsOwnRemote() throws {
        let need = try #require(GitHubSignInNeed(startCode: "seed.needs_github", details: nil, repo: "https://github.com/acme/app.git"))
        #expect(need.repo == "acme/app")
        #expect(GitHubSignInNeed.repo(remote: "git@github.com:acme/app.git") == "acme/app")
        #expect(GitHubSignInNeed.repo(remote: "https://gitlab.com/acme/app.git") == nil)
        // A malformed repository in the details is dropped, never passed to the connect.
        let bad: JSONValue = .object(["repo": .string("../etc")])
        #expect(try #require(GitHubSignInNeed(startCode: "seed.needs_github", details: bad)).repo == nil)
    }

    // MARK: A chat's GitHub call

    static func mcpRefusal(code: String, detail: String, connect: Bool = true) -> JSONValue {
        var error: [String: JSONValue] = ["code": .string(code), "detail": .string(detail), "repo": .string("acme/web")]
        if connect { error["connect"] = .object(["action": .string("accounts.githubConnect")]) }
        return .object(["structuredContent": .object(["error": .object(error)])])
    }

    @Test func thePermissionsRefusalShowsItsLine() throws {
        let call = ACPToolCall(id: "g1", title: "mcp__github__get_file_contents", kind: .other, status: .failed,
                               rawInput: .object(["owner": .string("acme"), "repo": .string("api")]),
                               rawOutput: Self.mcpRefusal(code: "github.permissions_pending", detail: "github.permissions_pending", connect: false))
        let need = try #require(GitHubSignInNeed(call: call))
        #expect(need.reason == .permissionsPending)
        // The call's own arguments name the repository first.
        #expect(need.repo == "acme/api")
        #expect(need.line == "GitHub needs you to accept cmux's updated permissions")
    }

    @Test func aNotConnectedRefusalNeedsTheConnectAction() throws {
        let call = ACPToolCall(id: "g1", title: "mcp__github__list_issues", kind: .other, status: .failed,
                               rawOutput: Self.mcpRefusal(code: "github.not_connected", detail: "integration.not_found"))
        #expect(try #require(GitHubSignInNeed(call: call)).reason == .notConnected)
        #expect(try #require(GitHubSignInNeed(call: call)).repo == "acme/web")
        var bare = call
        bare.rawOutput = Self.mcpRefusal(code: "github.not_connected", detail: "integration.not_found", connect: false)
        #expect(GitHubSignInNeed(call: bare) == nil)
        // Another server's error, or a call that worked, is not GitHub's refusal.
        var other = call
        other.title = "mcp__linear__list_issues"
        #expect(GitHubSignInNeed(call: other) == nil)
        var worked = call
        worked.status = .completed
        #expect(GitHubSignInNeed(call: worked) == nil)
    }

    @Test func aShellRefusalLineAsksWithNoRepository() throws {
        let line = "cmux github credential: acme/web: github.permissions_pending: accept the update. Next: open GitHub and accept; `cmux accounts github-connect`."
        let call = ACPToolCall(id: "s1", title: "git push", kind: .execute, status: .failed, content: [.content(.text(line))],
                               rawInput: .object(["command": .string("git push origin main")]))
        let need = try #require(GitHubSignInNeed(call: call))
        #expect(need.reason == .permissionsPending)
        #expect(need.repo == nil)
        // A shell that printed the words but did not run git or gh, or a file that only mentions them.
        var cat = call
        cat.rawInput = .object(["command": .string("cat notes.txt")])
        #expect(GitHubSignInNeed(call: cat) == nil)
        var mention = call
        mention.content = [.content(.text("see github.permissions_pending in the docs"))]
        #expect(GitHubSignInNeed(call: mention) == nil)
    }

    @Test func theTurnDrawsOneCardUnderItsWork() {
        var turn = AgentTurn(id: "t1", prompt: "open a PR", promptAt: Date(timeIntervalSince1970: 1_700_000_000))
        let refused = ACPToolCall(id: "g1", title: "mcp__github__create_pull_request", kind: .other, status: .failed,
                                  rawOutput: Self.mcpRefusal(code: "github.permissions_pending", detail: "github.permissions_pending", connect: false))
        var again = refused
        again.id = "g2"
        turn.items = [.tool(refused), .tool(again)]
        turn.status = .completed
        let rows = ChatTranscriptBuilder(diffs: ChatDiffCache()).build(turns: [turn], pendingPermission: nil, askOpen: false,
                                                                       permissionBarHidden: false)
        let cards = rows.flatMap(\.rows).filter { if case .githubSignIn = $0.kind { true } else { false } }
        #expect(cards.count == 1)
        #expect(cards.first?.id == "g-t1")
    }
}
