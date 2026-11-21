import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextDiff

@MainActor
struct DiffPatchPagesTests {
    private func reply(_ bytes: Data, offset: Int, total: Int, revision: String = String(repeating: "a", count: 64)) -> JSONValue {
        let next = offset + bytes.count
        return ["patch_page": ["offset": .string(String(offset)), "next_offset": .string(String(next)),
            "total_bytes": .string(String(total)), "revision": .string(revision),
            "data_base64": .string(bytes.base64EncodedString()), "complete": .bool(next == total)]]
    }

    @Test func multibyteTextCanCrossABytePageBoundary() async throws {
        let bytes = Data("café end\n".utf8)
        var calls = 0
        let joined = try await DiffPatchPages.read { offset, revision in
            #expect(revision == (offset == 0 ? nil : String(repeating: "a", count: 64)))
            calls += 1
            let start = Int(offset), end = min(start + 4, bytes.count)
            return reply(bytes.subdata(in: start..<end), offset: start, total: bytes.count)
        }
        #expect(joined == bytes)
        #expect(calls == 3)
    }

    @Test func changedRevisionAndNoProgressBothStopTheRead() async {
        var calls = 0
        await #expect(throws: PageError.self) {
            _ = try await DiffPatchPages.read { offset, _ in
                calls += 1
                return reply(Data([0x61]), offset: Int(offset), total: 3,
                             revision: String(repeating: offset == 0 ? "a" : "b", count: 64))
            }
        }
        #expect(calls == 2)
        calls = 0
        await #expect(throws: PageError.self) {
            _ = try await DiffPatchPages.read { _, _ in
                calls += 1
                return reply(Data(), offset: 0, total: 3)
            }
        }
        #expect(calls == 1)
    }

    @Test func cancellationStopsBeforeAskingForAnotherPage() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await DiffPatchPages.read { _, _ in
                Issue.record("a cancelled read must not request any pages")
                return reply(Data(), offset: 0, total: 0)
            }
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test func aCapturePastTheExistingViewerBudgetIsRefusedBeforeAllocation() async {
        var calls = 0
        await #expect(throws: PageError.self) {
            _ = try await DiffPatchPages.read { _, _ in
                calls += 1
                return reply(Data([0x61]), offset: 0, total: DiffPatchResolver.maximumPatchBytes + 1)
            }
        }
        #expect(calls == 1)
    }

    /// One file's read stops at the local viewer's size rule (the sidecar's 2 MiB a side): a larger
    /// patch reads no page past the first, and the page answers tooLarge, so four reads at once never
    /// join hundreds of MiB or evict each other's daemon capture (review of fcd87b662c5).
    @Test func aFilePatchPastTheSideLimitStopsAfterTheFirstPage() async throws {
        var calls = 0
        let joined = try await DiffPatchPages.read { _, _ in
            calls += 1
            return reply(Data([0x61]), offset: 0, total: DiffPatchPages.maximumFilePatchBytes + 1)
        }
        #expect(joined == nil)
        #expect(calls == 1)
    }
}
