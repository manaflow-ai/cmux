import Testing

@testable import CmuxGit

@Suite struct GitDiffServiceFileSectionTests {
    @Test func unicodeLineSeparatorInContentDoesNotStartAnotherFileSection() {
        let output = """
        diff --git a/File.swift b/File.swift
        @@ -0,0 +1 @@
        +before diff --git a/Other.swift b/Other.swift
        """

        #expect(GitDiffService.hasExactlyOneFileSection(output))
    }

    @Test func unicodeLineSeparatorsInContentDoNotSatisfyRenameMetadata() {
        let output = """
        diff --git a/File.swift b/File.swift
        @@ -0,0 +1 @@
        +before rename from Other.swift rename to Other.swift
        """

        #expect(!GitDiffService.hasRenameHeaders(output))
    }

    @Test(arguments: [
        ("new file mode 100644", GitDiffStatus.added),
        ("deleted file mode 100644", GitDiffStatus.deleted),
        ("index 1111111..2222222 100644", GitDiffStatus.modified),
    ])
    func classifiesTrackedFileSection(metadata: String, expected: GitDiffStatus) {
        let output = "diff --git a/File.swift b/File.swift\n\(metadata)\n"

        #expect(GitDiffService.fileSectionStatus(output) == expected)
    }

    @Test func classifiesRenameOnlyWithPairedProtocolHeaders() {
        let output = """
        diff --git a/Old.swift b/New.swift
        rename from Old.swift
        rename to New.swift
        """

        #expect(GitDiffService.fileSectionStatus(output) == .renamed)
    }

    @Test func contentCannotSpoofTrackedFileStatus() {
        let output = """
        diff --git a/File.swift b/File.swift
        @@ -1 +1,3 @@
        -old
        +new file mode 100644
        +deleted file mode 100644
        +rename from Other.swift
        +rename to Other.swift
        """

        #expect(GitDiffService.fileSectionStatus(output) == .modified)
    }
}
