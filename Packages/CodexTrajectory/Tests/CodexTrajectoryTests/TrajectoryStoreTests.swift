import XCTest
@testable import CodexTrajectory

final class TrajectoryStoreTests: XCTestCase {
    func testAppendAndStreamingUpdatesPreserveStableBlockIdentity() {
        var store = CodexTrajectoryStore()
        store.append(
            CodexTrajectoryBlock(
                id: "assistant-1",
                kind: .assistantText,
                title: "Codex",
                text: "hello",
                isStreaming: true
            )
        )

        store.appendText(" world", toBlock: "assistant-1")
        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(store[id: "assistant-1"]?.displayText, "Codex\nhello world")
        XCTAssertEqual(store[id: "assistant-1"]?.isStreaming, true)

        store.setStreaming(false, forBlock: "assistant-1")
        XCTAssertEqual(store[id: "assistant-1"]?.isStreaming, false)
    }

    func testAppendWithExistingIDReplacesBlock() {
        var store = CodexTrajectoryStore()
        store.append(CodexTrajectoryBlock(id: "same", kind: .status, text: "old"))
        store.append(CodexTrajectoryBlock(id: "same", kind: .stderr, text: "new"))

        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(store[id: "same"]?.kind, .stderr)
        XCTAssertEqual(store[id: "same"]?.text, "new")
    }

    func testInitWithDuplicateIDsKeepsLastBlockWithoutCrashing() {
        let store = CodexTrajectoryStore(blocks: [
            CodexTrajectoryBlock(id: "same", kind: .status, text: "old"),
            CodexTrajectoryBlock(id: "same", kind: .stderr, text: "new"),
        ])

        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(store[id: "same"]?.kind, .stderr)
        XCTAssertEqual(store[id: "same"]?.text, "new")
    }
}
