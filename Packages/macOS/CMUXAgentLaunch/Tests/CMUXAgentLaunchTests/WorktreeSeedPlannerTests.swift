import Foundation
import Testing
import CMUXAgentLaunch

/// A repository the planner can walk without a filesystem.
///
/// Built from paths: a path ending in `/` is a directory, and every parent
/// directory is implied. `escaping` names symlinks that resolve out of the
/// repository, `directoryCount` records what a plan actually listed.
final class WorktreeSeedFakeRepository: @unchecked Sendable {
    private var children: [String: [WorktreeSeedListedEntry]] = [:]
    private(set) var listedDirectories: [String] = []

    init(_ paths: [String], escaping: Set<String> = []) {
        var directories: Set<String> = [""]
        for path in paths where path.hasSuffix("/") {
            directories.insert(String(path.dropLast()))
        }
        for path in paths {
            let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
            var segments = trimmed.split(separator: "/").map(String.init)
            let name = segments.removeLast()
            var parent = ""
            for segment in segments {
                directories.insert(parent.isEmpty ? segment : parent + "/" + segment)
                parent = parent.isEmpty ? segment : parent + "/" + segment
            }
            let isDirectory = path.hasSuffix("/") || directories.contains(trimmed)
            children[parent, default: []].append(
                WorktreeSeedListedEntry(
                    name: name,
                    isDirectory: isDirectory,
                    escapesRepository: escaping.contains(trimmed)
                )
            )
        }
        for directory in directories where children[directory] == nil {
            children[directory] = []
        }
        for (directory, entries) in children {
            children[directory] = entries.sorted { $0.name < $1.name }
        }
    }

    func planner(maximumVisitedDirectories: Int = 20_000) -> WorktreeSeedPlanner {
        WorktreeSeedPlanner(maximumVisitedDirectories: maximumVisitedDirectories) { [self] directory in
            record(directory)
            return children[directory] ?? []
        }
    }

    private func record(_ directory: String) {
        listedDirectories.append(directory)
    }
}

@Suite("worktreeinclude plans")
struct WorktreeSeedPlannerTests {
    private func plan(
        _ text: String,
        _ repository: WorktreeSeedFakeRepository,
        alreadyPresent: Set<String> = [],
        maximumVisitedDirectories: Int = 20_000
    ) -> WorktreeSeedPlan {
        repository.planner(maximumVisitedDirectories: maximumVisitedDirectories)
            .plan(for: WorktreeSeedFile.parse(text), alreadyPresent: alreadyPresent)
    }

    @Test func aPatternIsAPathFromTheRepositoryRoot() {
        let repository = WorktreeSeedFakeRepository([".env", "web/", "web/.env"])
        let plan = plan(".env", repository)
        #expect(plan.entries.map(\.relativePath) == [".env"])
    }

    @Test func aRootPatternDoesNotWalkIntoSubdirectories() {
        let repository = WorktreeSeedFakeRepository([".env", "node_modules/", "node_modules/a/", "node_modules/a/b"])
        _ = plan(".env", repository)
        #expect(repository.listedDirectories == [""])
    }

    @Test func aNestedPatternListsOnlyTheDirectoriesOnItsPath() {
        let repository = WorktreeSeedFakeRepository([
            "config/", "config/local.json", "node_modules/", "node_modules/a/", "web/", "web/x",
        ])
        _ = plan("config/local.json", repository)
        #expect(repository.listedDirectories == ["", "config"])
    }

    @Test func starMatchesWithinOneSegmentOnly() {
        let repository = WorktreeSeedFakeRepository([".env", ".env.local", "config/", "config/.env.ci"])
        let plan = plan(".env*", repository)
        #expect(plan.entries.map(\.relativePath) == [".env", ".env.local"])
    }

    @Test func questionMarkMatchesOneCharacter() {
        let repository = WorktreeSeedFakeRepository(["a.env", "ab.env", ".env"])
        #expect(plan("?.env", WorktreeSeedFakeRepository(["a.env", "ab.env", ".env"])).entries.map(\.relativePath) == ["a.env"])
        _ = repository
    }

    @Test func doubleStarIsHowAPatternOptsIntoAWalk() {
        let repository = WorktreeSeedFakeRepository([
            "a/", "a/.env", "a/b/", "a/b/.env", "a/b/c/", "a/b/c/other",
        ])
        let plan = plan("a/**/.env", repository)
        #expect(plan.entries.map(\.relativePath) == ["a/.env", "a/b/.env"])
    }

    @Test func aTrailingDoubleStarTakesEverythingBelowButNotTheDirectoryItself() {
        let repository = WorktreeSeedFakeRepository(["secrets/", "secrets/a", "secrets/b/", "secrets/b/c"])
        let plan = plan("secrets/**", repository)
        #expect(plan.entries.map(\.relativePath) == ["secrets/a", "secrets/b"])
        #expect(plan.shadowed.map(\.relativePath) == ["secrets/b/c"])
    }

    @Test func aTrailingSlashSelectsDirectoriesOnly() {
        let repository = WorktreeSeedFakeRepository(["build", "build-dir/", "build-dir/x"])
        let plan = plan("build*/", repository)
        #expect(plan.entries.map(\.relativePath) == ["build-dir"])
        #expect(plan.entries.map(\.isDirectory) == [true])
    }

    @Test func aDirectoryWithoutATrailingSlashIsStillSelectedWhole() {
        let repository = WorktreeSeedFakeRepository(["node_modules/", "node_modules/a/", "node_modules/a/b"])
        let plan = plan("node_modules", repository)
        #expect(plan.entries.count == 1)
        #expect(plan.entries[0].relativePath == "node_modules")
        #expect(plan.entries[0].isDirectory)
    }

    @Test func theLinkKeywordCarriesToThePlan() {
        let repository = WorktreeSeedFakeRepository([".env", "node_modules/"])
        let plan = plan(".env\nlink node_modules\n", repository)
        #expect(plan.copies.map(\.relativePath) == [".env"])
        #expect(plan.links.map(\.relativePath) == ["node_modules"])
    }

    @Test func theLastMatchingLineDecides() {
        let repository = WorktreeSeedFakeRepository([".env", ".env.production"])
        let plan = plan(".env*\n!.env.production\n", repository)
        #expect(plan.entries.map(\.relativePath) == [".env"])
        #expect(plan.excluded.map(\.relativePath) == [".env.production"])
        #expect(plan.excluded.map(\.line) == [2])
    }

    @Test func aNegationBeforeItsPatternDoesNothing() {
        let repository = WorktreeSeedFakeRepository([".env", ".env.production"])
        let plan = plan("!.env.production\n.env*\n", repository)
        #expect(plan.entries.map(\.relativePath) == [".env", ".env.production"])
        #expect(plan.excluded.isEmpty)
    }

    @Test func aLaterLineCanChangeAnActionWithoutRepeatingTheNegation() {
        let repository = WorktreeSeedFakeRepository(["node_modules/"])
        let plan = plan("node_modules\nlink node_modules\n", repository)
        #expect(plan.links.map(\.relativePath) == ["node_modules"])
        #expect(plan.copies.isEmpty)
        #expect(plan.entries.map(\.line) == [2])
    }

    @Test func anEntryUnderASelectedDirectoryIsDropped() {
        let repository = WorktreeSeedFakeRepository(["node_modules/", "node_modules/.bin/", "node_modules/.bin/tsc"])
        let plan = plan("link node_modules\nnode_modules/.bin/tsc\n", repository)
        #expect(plan.entries.map(\.relativePath) == ["node_modules"])
        #expect(plan.shadowed == [
            WorktreeSeedShadow(
                relativePath: "node_modules/.bin/tsc",
                coveredBy: "node_modules",
                coveringAction: .link
            ),
        ])
    }

    @Test func aNegationInsideASelectedDirectoryIsReportedRatherThanIgnored() {
        let repository = WorktreeSeedFakeRepository([
            "node_modules/", "node_modules/.cache/", "node_modules/.cache/big",
        ])
        let plan = plan("link node_modules\n!node_modules/.cache\n", repository)
        #expect(plan.entries.map(\.relativePath) == ["node_modules"])
        #expect(plan.ineffectiveNegations == [
            WorktreeSeedShadow(
                relativePath: "node_modules/.cache",
                coveredBy: "node_modules",
                coveringAction: .link
            ),
        ])
    }

    @Test func aNegatedPositiveMatchInsideASelectedDirectoryIsStillIneffective() {
        let repository = WorktreeSeedFakeRepository([
            "node_modules/", "node_modules/.cache/", "node_modules/.cache/big",
        ])
        let plan = plan(
            "link node_modules\nnode_modules/**\n!node_modules/.cache\n",
            repository
        )
        #expect(plan.entries.map(\.relativePath) == ["node_modules"])
        #expect(plan.excluded.map(\.relativePath) == ["node_modules/.cache"])
        #expect(plan.ineffectiveNegations == [
            WorktreeSeedShadow(
                relativePath: "node_modules/.cache",
                coveredBy: "node_modules",
                coveringAction: .link
            ),
        ])
    }

    @Test func shadowsAndNegationsNameTheOperativeRetainedRoot() {
        let repository = WorktreeSeedFakeRepository([
            "root/", "root/sub/", "root/sub/secret",
        ])
        let plan = plan(
            "link root\ncopy root/sub\n!root/sub/secret\n",
            repository
        )

        #expect(plan.entries.map(\.relativePath) == ["root"])
        #expect(plan.entries.map(\.action) == [.link])
        #expect(plan.shadowed == [
            WorktreeSeedShadow(
                relativePath: "root/sub",
                coveredBy: "root",
                coveringAction: .link
            ),
        ])
        #expect(plan.ineffectiveNegations == [
            WorktreeSeedShadow(
                relativePath: "root/sub/secret",
                coveredBy: "root",
                coveringAction: .link
            ),
        ])
    }

    @Test func aSymlinkOutOfTheRepositoryIsRefused() {
        let repository = WorktreeSeedFakeRepository([".env", "shared/"], escaping: ["shared"])
        let plan = plan(".env\nshared\n", repository)
        #expect(plan.entries.map(\.relativePath) == [".env"])
        #expect(plan.refused.map(\.relativePath) == ["shared"])
    }

    @Test func aPathTheWorktreeAlreadyHasIsLeftAlone() {
        let repository = WorktreeSeedFakeRepository([".env", "config/", "config/local.json"])
        let plan = plan(".env\nconfig/local.json\n", repository, alreadyPresent: ["config/local.json"])
        #expect(plan.entries.map(\.relativePath) == [".env"])
        #expect(plan.alreadyPresent.map(\.relativePath) == ["config/local.json"])
    }

    @Test func aPatternThatMatchesNothingIsNamed() {
        let repository = WorktreeSeedFakeRepository([".env"])
        let plan = plan(".env\n.env.gone\nlink node_modules\n", repository)
        #expect(plan.unmatched.map(\.glob) == [".env.gone", "node_modules"])
        #expect(plan.unmatched.map(\.line) == [2, 3])
    }

    @Test func aWalkThatHitsTheBudgetSaysSo() {
        var paths: [String] = []
        var prefix = "a"
        for _ in 0..<40 {
            paths.append(prefix + "/")
            paths.append(prefix + "/.env")
            prefix += "/a"
        }
        let repository = WorktreeSeedFakeRepository(paths)
        let plan = plan("**/.env", repository, maximumVisitedDirectories: 5)
        #expect(plan.reachedWalkLimit)
        #expect(repository.listedDirectories.count <= 5)
    }

    @Test func aPlanThatStaysInBudgetDoesNotClaimALimit() {
        let repository = WorktreeSeedFakeRepository(["a/", "a/.env"])
        #expect(!plan("**/.env", repository).reachedWalkLimit)
    }

    @Test func anEmptyFilePlansNothing() {
        let repository = WorktreeSeedFakeRepository([".env"])
        let plan = plan("# nothing\n", repository)
        #expect(plan.isEmpty)
        #expect(plan.unmatched.isEmpty)
    }

    @Test func plansAreOrderedByPathSoTheyCanBeCompared() {
        let repository = WorktreeSeedFakeRepository(["z.env", "a.env", "m/", "m/local.json"])
        let plan = plan("z.env\nm/local.json\na.env\n", repository)
        #expect(plan.entries.map(\.relativePath) == ["a.env", "m/local.json", "z.env"])
    }

    @Test func aBadLineDoesNotStopTheGoodOnesFromBeingPlanned() {
        let repository = WorktreeSeedFakeRepository([".env"])
        let file = WorktreeSeedFile.parse("/nope\n.env\n")
        let plan = repository.planner().plan(for: file)
        #expect(plan.entries.map(\.relativePath) == [".env"])
        #expect(file.problems.count == 1)
    }

    @Test func aPathologicalGlobDoesNotHang() {
        let name = String(repeating: "a", count: 200)
        let repository = WorktreeSeedFakeRepository([name])
        let plan = plan("*a*a*a*a*a*b", repository)
        #expect(plan.entries.isEmpty)
        #expect(plan.unmatched.count == 1)
    }

    @Test func repeatedDoubleStarSegmentsDoNotRevisitTheSameStates() throws {
        let text = (Array(repeating: "**", count: 40) + ["never"]).joined(separator: "/")
        let pattern = try #require(WorktreeSeedFile.parse(text).patterns.first)
        let path = Array(repeating: "segment", count: 80).joined(separator: "/")
        #expect(!WorktreeSeedPlanner.pattern(pattern, matches: path, isDirectory: false))
    }

    @Test func anEscapedStarMatchesALiteralStar() {
        let repository = WorktreeSeedFakeRepository(["star*name", "starXname"])
        let plan = plan("star\\*name", repository)
        #expect(plan.entries.map(\.relativePath) == ["star*name"])
    }

    @Test func aLeadingEscapedMetacharacterStaysLiteral() {
        let repository = WorktreeSeedFakeRepository([
            "*.env", "prod.env", "?.secret", "a.secret",
        ])
        let plan = plan("\\*.env\n\\?.secret\n", repository)
        #expect(plan.entries.map(\.relativePath) == ["*.env", "?.secret"])
    }
}
