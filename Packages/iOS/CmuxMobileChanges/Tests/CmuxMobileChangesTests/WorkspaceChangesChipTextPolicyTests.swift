import Foundation
import Testing

@testable import CmuxMobileChanges

@Suite("Workspace changes chip text policy")
struct WorkspaceChangesChipTextPolicyTests {
    private let englishPolicy = WorkspaceChangesChipTextPolicy(
        locale: Locale(identifier: "en")
    )

    @Test("zero totals keep the normal additions and deletions format")
    func zeroLineCounts() {
        let text = englishPolicy.text(filesChanged: 0, additions: 0, deletions: 0)

        #expect(text.primary == "+0")
        #expect(text.secondary == "−0")
        #expect(text.combined == "+0 −0")
    }

    @Test("nonzero line totals keep the normal additions and deletions format")
    func nonzeroLineCounts() {
        let text = englishPolicy.text(filesChanged: 9, additions: 48, deletions: 10)

        #expect(text.primary == "+48")
        #expect(text.secondary == "−10")
        #expect(text.combined == "+48 −10")
    }

    @Test("one binary-only change uses the singular file count")
    func binaryOnlySingularFileCount() {
        let text = englishPolicy.text(filesChanged: 1, additions: 0, deletions: 0)

        #expect(text.primary == "1 file")
        #expect(text.secondary == nil)
        #expect(text.combined == "1 file")
    }

    @Test("multiple binary-only changes use the plural file count")
    func binaryOnlyPluralFileCount() {
        let text = englishPolicy.text(filesChanged: 3, additions: 0, deletions: 0)

        #expect(text.primary == "3 files")
        #expect(text.secondary == nil)
    }
}
