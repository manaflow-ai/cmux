import CmuxNextCompat
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The agent panes' small state files save off the main thread, in order, and a store made right
/// after a save reads it back (cmux#27587 follow-up: under agent disk load one such save on the
/// main thread took 1.0 s at p95).
@Suite(.serialized)
@MainActor
struct AgentPaneStateFileTests {
    static func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "state-file-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func aSaveRunsOffTheMainThreadAndAReadSeesIt() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = AgentPaneStateFile.at(directory.appending(path: "a.json"))
        let onMain = Mutex<Bool?>(nil)
        file.write {
            onMain.withLock { $0 = Thread.isMainThread }
            return Data("one".utf8)
        }
        #expect(file.read() == Data("one".utf8))
        #expect(onMain.withLock { $0 } == false, "the save ran on the main thread")
    }

    @Test func aBurstOfSavesEndsWithTheLast() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "b.json")
        let file = AgentPaneStateFile.at(url)
        for value in 1...50 {
            file.write { Data("\(value)".utf8) }
        }
        // One store per file: a second one for the same path shares the queue, so it reads the last.
        #expect(AgentPaneStateFile.at(url).read() == Data("50".utf8))
        // nil removes the file.
        file.write { nil }
        #expect(file.read() == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func flushAllWaitsForQueuedSaves() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "c.json")
        AgentPaneStateFile.at(url).write { Data("quit".utf8) }
        AgentPaneStateFile.flushAll()
        #expect((try? Data(contentsOf: url)) == Data("quit".utf8))
    }

    @Test func unsentDraftsAndScrollPlacesSurviveAFreshStore() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let drafts = AgentUnsentDrafts(directory: directory)
        drafts.set("first", for: "tab-1")
        drafts.set("second", for: "tab-1")
        let relaunched = AgentUnsentDrafts(directory: directory)
        #expect(relaunched.hasDraft("tab-1"))
        let anchors = AgentPaneScrollAnchors(directory: directory)
        anchors.remember(AgentPaneScrollAnchor(rowId: "row-3", offset: 4), for: "s-1")
        #expect(AgentPaneScrollAnchors(directory: directory).anchor(for: "s-1") == AgentPaneScrollAnchor(rowId: "row-3", offset: 4))
    }
}
