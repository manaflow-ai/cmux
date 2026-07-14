import Testing

@testable import CmuxGit

@Suite struct WorkspaceGitStatusParserTests {
    @Test func parsesPorcelainAndNumstatFixture() throws {
        let porcelain = [
            " M modified.txt",
            "A  staged.txt",
            " D deleted.txt",
            "R  renamed.txt",
            "old-name.txt",
            " M binary.dat",
            "?? untracked.txt",
            "",
        ].joined(separator: "\0")
        let trackedNumstat = [
            "12\t3\tmodified.txt",
            "4\t0\tstaged.txt",
            "0\t8\tdeleted.txt",
            "2\t1\t",
            "old-name.txt",
            "renamed.txt",
            "-\t-\tbinary.dat",
            "",
        ].joined(separator: "\0")
        let files = try WorkspaceGitStatusParser().parse(
            porcelain: porcelain,
            trackedNumstat: trackedNumstat,
            untrackedStatsByPath: [
                "untracked.txt": WorkspaceGitNumstatEntry(
                    path: "untracked.txt", oldPath: nil,
                    additions: 5, deletions: 0, binary: false
                ),
            ]
        )

        #expect(files == [
            WorkspaceGitStatusFile(
                path: "modified.txt", oldPath: nil, status: "M",
                additions: 12, deletions: 3, binary: false, untracked: false
            ),
            WorkspaceGitStatusFile(
                path: "staged.txt", oldPath: nil, status: "A",
                additions: 4, deletions: 0, binary: false, untracked: false
            ),
            WorkspaceGitStatusFile(
                path: "deleted.txt", oldPath: nil, status: "D",
                additions: 0, deletions: 8, binary: false, untracked: false
            ),
            WorkspaceGitStatusFile(
                path: "renamed.txt", oldPath: "old-name.txt", status: "R",
                additions: 2, deletions: 1, binary: false, untracked: false
            ),
            WorkspaceGitStatusFile(
                path: "binary.dat", oldPath: nil, status: "M",
                additions: 0, deletions: 0, binary: true, untracked: false
            ),
            WorkspaceGitStatusFile(
                path: "untracked.txt", oldPath: nil, status: "A",
                additions: 5, deletions: 0, binary: false, untracked: true
            ),
        ])
        #expect(files.reduce(0) { $0 + $1.additions } == 23)
        #expect(files.reduce(0) { $0 + $1.deletions } == 12)
    }

    @Test func untrackedEmptyFileHasZeroCounts() throws {
        let files = try WorkspaceGitStatusParser().parse(
            porcelain: "?? empty.txt\0",
            trackedNumstat: "",
            untrackedStatsByPath: [:]
        )

        #expect(files == [
            WorkspaceGitStatusFile(
                path: "empty.txt", oldPath: nil, status: "A",
                additions: 0, deletions: 0, binary: false, untracked: true
            ),
        ])
    }

    @Test func copiedPorcelainEntryConsumesSourcePathAndMapsToAdded() throws {
        // `--porcelain=v1 -z` emits the destination in the status record and
        // the copy source as the immediately following NUL record.
        let entries = try WorkspaceGitStatusParser().parsePorcelain(
            "C  copied.swift\0original.swift\0 M later.swift\0"
        )

        #expect(entries == [
            WorkspaceGitPorcelainEntry(
                path: "copied.swift",
                oldPath: "original.swift",
                status: "A",
                untracked: false
            ),
            WorkspaceGitPorcelainEntry(
                path: "later.swift",
                oldPath: nil,
                status: "M",
                untracked: false
            ),
        ])
    }
}
