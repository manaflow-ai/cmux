import Foundation
import Testing
import CMUXAgentLaunch

@Suite("worktreeinclude lines")
struct WorktreeSeedPatternTests {
    private func parse(_ line: String, number: Int = 1) -> Result<WorktreeSeedPattern?, WorktreeSeedProblem> {
        WorktreeSeedPattern.parse(line: line, number: number)
    }

    private func pattern(_ line: String, number: Int = 1) throws -> WorktreeSeedPattern {
        switch parse(line, number: number) {
        case .success(let pattern?): return pattern
        case .success(nil): throw TestFailure("line \(line) was skipped, expected a pattern")
        case .failure(let problem): throw TestFailure("line \(line) was rejected: \(problem)")
        }
    }

    private func problem(_ line: String, number: Int = 1) throws -> WorktreeSeedProblem {
        switch parse(line, number: number) {
        case .failure(let problem): return problem
        default: throw TestFailure("line \(line) was accepted, expected a problem")
        }
    }

    struct TestFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    @Test func blankAndCommentLinesSelectNothing() {
        for line in ["", "   ", "\t", "# a comment", "   # indented comment"] {
            #expect(try! parse(line).get() == nil, "\(line.debugDescription) should be skipped")
        }
    }

    @Test func aPlainLineCopiesOnePath() throws {
        let pattern = try pattern(".env")
        #expect(pattern.glob == ".env")
        #expect(pattern.action == .copy)
        #expect(!pattern.isNegated)
        #expect(!pattern.directoryOnly)
        #expect(pattern.segments == [".env"])
    }

    @Test func theLinkKeywordChangesTheAction() throws {
        #expect(try pattern("link node_modules").action == .link)
        #expect(try pattern("link\tnode_modules").action == .link)
        #expect(try pattern("link   node_modules").glob == "node_modules")
    }

    @Test func aWordStartingWithLinkIsStillAPath() throws {
        let pattern = try pattern("linked-config.json")
        #expect(pattern.action == .copy)
        #expect(pattern.glob == "linked-config.json")
    }

    @Test func aBackslashEscapesAKeywordPath() throws {
        #expect(try pattern("\\link me").glob == "link me")
        #expect(try pattern("\\#not-a-comment").glob == "#not-a-comment")
        #expect(try pattern("\\!not-a-negation").glob == "!not-a-negation")
    }

    @Test func bangNegates() throws {
        let pattern = try pattern("!config/local.secret.json")
        #expect(pattern.isNegated)
        #expect(pattern.glob == "config/local.secret.json")
    }

    @Test func aNegationTakesNoActionKeyword() throws {
        let problem = try problem("!link node_modules")
        #expect(problem.reason == .negatedActionKeyword)
        #expect(problem.description.contains("!node_modules"))
    }

    @Test func aKeywordWithNothingAfterItIsAPathNamedAfterTheKeyword() throws {
        // Trailing whitespace goes before the keyword is read, so there is no
        // "keyword with an empty pattern" state to report: `link` on its own is a
        // path, and an absent one shows up as an unmatched pattern in the plan.
        #expect(try pattern("link").glob == "link")
        #expect(try pattern("link ").glob == "link")
        #expect(try pattern("link\t\t").glob == "link")
        #expect(try pattern("link").action == .copy)
    }

    @Test func aTrailingSlashMeansDirectoryOnly() throws {
        let pattern = try pattern("build/")
        #expect(pattern.directoryOnly)
        #expect(pattern.glob == "build")
        #expect(try self.pattern("build//").directoryOnly)
    }

    @Test func aLeadingSlashIsRejectedBecausePatternsAreAlreadyRelative() throws {
        let problem = try problem("/Users/leo/.env", number: 4)
        #expect(problem.reason == .leadingSlash)
        #expect(problem.line == 4)
        #expect(problem.description.contains("line 4"))
    }

    @Test func aHomePathIsRejected() throws {
        #expect(try problem("~/.aws/credentials").reason == .homeRelative)
    }

    @Test func aDotDotSegmentIsRejected() throws {
        #expect(try problem("../secrets/.env").reason == .escapesRepository)
        #expect(try problem("config/../../.env").reason == .escapesRepository)
    }

    @Test func aLineOfSeparatorsIsRejected() throws {
        #expect(try problem("/").reason == .leadingSlash)
        #expect(try problem("\\").reason == .emptyPattern)
    }

    @Test func trailingWhitespaceIsNotPartOfAFilename() throws {
        #expect(try pattern(".env   ").glob == ".env")
        #expect(try pattern("\tconfig/local.json\t").glob == "config/local.json")
    }

    @Test func anEscapedTrailingSpaceIsPartOfAFilename() throws {
        #expect(try pattern("odd-name\\ ").glob == "odd-name ")
    }

    @Test func innerSlashesAreNormalized() throws {
        #expect(try pattern("config//local.json").glob == "config/local.json")
        #expect(try pattern("config/local.json").segments == ["config", "local.json"])
    }

    @Test func theLineNumberIsCarried() throws {
        #expect(try pattern(".env", number: 12).line == 12)
    }
}
