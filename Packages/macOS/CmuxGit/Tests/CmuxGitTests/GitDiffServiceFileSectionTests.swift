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
}
