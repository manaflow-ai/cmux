import CmuxMobileChanges
import Foundation
import Testing

@testable import CmuxMobileShell

@Suite struct WorkspaceChangesExpansionDownloadPolicyTests {
    private let byteLimit: Int64 = 5 * 1_024 * 1_024
    private let chunkLength = 3 * 1_024 * 1_024

    @Test func rejectsReportedTotalSizeAboveExpansionCap() {
        let policy = WorkspaceChangesExpansionDownloadPolicy(
            byteLimit: byteLimit,
            chunkLength: chunkLength
        )

        #expect(throws: DiffExpansionContentError.tooLarge) {
            try policy.validate(
                totalSize: byteLimit + 1,
                accumulatedByteCount: 0,
                nextChunkByteCount: 0,
                receivedChunkCount: 1
            )
        }
    }

    @Test func rejectsChunkThatWouldCrossCumulativeByteCap() {
        let policy = WorkspaceChangesExpansionDownloadPolicy(
            byteLimit: byteLimit,
            chunkLength: chunkLength
        )

        #expect(throws: DiffExpansionContentError.tooLarge) {
            try policy.validate(
                totalSize: byteLimit,
                accumulatedByteCount: Int(byteLimit) - 1,
                nextChunkByteCount: 2,
                receivedChunkCount: 2
            )
        }
    }

    @Test func rejectsMoreThanCeilingChunkCountPlusTwo() {
        let policy = WorkspaceChangesExpansionDownloadPolicy(
            byteLimit: byteLimit,
            chunkLength: chunkLength
        )

        #expect(policy.maximumChunkCount == 4)
        #expect(throws: DiffExpansionContentError.tooLarge) {
            try policy.validate(
                totalSize: byteLimit,
                accumulatedByteCount: Int(byteLimit),
                nextChunkByteCount: 0,
                receivedChunkCount: policy.maximumChunkCount + 1
            )
        }
    }

    @Test func currentLineMaterializationRejectsMoreThanTwoHundredThousandLines() async {
        let data = Data(
            String(
                repeating: "line\n",
                count: MobileShellComposite.workspaceChangesExpansionLineLimit + 1
            ).utf8
        )

        await #expect(throws: DiffExpansionContentError.tooLarge) {
            try await MobileShellComposite.workspaceChangesLines(from: data)
        }
    }
}
