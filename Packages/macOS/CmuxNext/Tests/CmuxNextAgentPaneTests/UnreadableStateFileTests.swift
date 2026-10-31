import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A state file this run cannot read is set aside beside itself, never written over: two set aside
/// in one second keep both, and a name that is taken gets another (cmux#27963 review).
struct UnreadableStateFileTests {
    static func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "unreadable-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func aTakenNameGetsAnotherAndKeepsBoth() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "state.json")
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let taken = directory.appending(path: "state.unreadable-2000000000-taken.json")
        try Data("earlier".utf8).write(to: taken)
        try Data("{\"half".utf8).write(to: file)

        var ids = ["taken", "fresh"].makeIterator()
        let aside = try UnreadableStateFile.setAside(file, now: now) { ids.next()! }
        #expect(aside.lastPathComponent == "state.unreadable-2000000000-fresh.json")
        #expect(try Data(contentsOf: taken) == Data("earlier".utf8))
        #expect(try Data(contentsOf: aside) == Data("{\"half".utf8))
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func aFileWhoseEveryNameIsTakenIsLeftInPlace() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "state.json")
        try Data("{\"half".utf8).write(to: file)
        try Data("x".utf8).write(to: directory.appending(path: "state.unreadable-0-taken.json"))
        #expect(throws: (any Error).self) {
            try UnreadableStateFile.setAside(file, now: Date(timeIntervalSince1970: 0)) { "taken" }
        }
        #expect(try Data(contentsOf: file) == Data("{\"half".utf8), "a file that was not moved is left as it was")
    }
}
