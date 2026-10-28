@testable import CmuxNextTasks
import Foundation
import Testing

/// A Tasks owner snapshot with two rows under one id is corrupt input: the wire refuses it
/// with a typed error instead of trapping in `Dictionary(uniqueKeysWithValues:)`.
@MainActor
struct TasksSnapshotDuplicateIDTests {
    private struct SnapshotLine: Encodable {
        var snapshot: TasksSnapshot
    }

    private func line(_ snapshot: TasksSnapshot) throws -> Data {
        try JSONEncoder().encode(SnapshotLine(snapshot: snapshot))
    }

    @Test func theSeedHasUniqueIDs() throws {
        try MockTasksSource.seed().checkUniqueIDs()
    }

    @Test func aRepeatedTaskIDThrowsATypedError() throws {
        var snapshot = MockTasksSource.seed()
        let task = try #require(snapshot.tasks.first)
        snapshot.tasks.append(task)
        #expect(throws: TasksSnapshotError.duplicateID(entity: "task", id: task.id)) {
            try snapshot.checkUniqueIDs()
        }
    }

    @Test func aRepeatedStatusIDThrowsATypedError() throws {
        var snapshot = MockTasksSource.seed()
        let status = try #require(snapshot.statuses.last)
        snapshot.statuses.insert(status, at: 0)
        #expect(throws: TasksSnapshotError.duplicateID(entity: "status", id: status.id)) {
            try snapshot.checkUniqueIDs()
        }
    }

    @Test func theWireRefusesASnapshotWithARepeatedID() throws {
        var snapshot = MockTasksSource.seed()
        let label = try #require(snapshot.labels.first)
        snapshot.labels.append(label)
        guard case .badSnapshot(let error) = TasksWire.decode(try line(snapshot)) else {
            Issue.record("a snapshot with a repeated label id decoded as a snapshot")
            return
        }
        #expect(error == .duplicateID(entity: "label", id: label.id))
    }

    @Test func theWirePassesASnapshotWithUniqueIDs() throws {
        let snapshot = MockTasksSource.seed()
        guard case .snapshot(let decoded) = TasksWire.decode(try line(snapshot)) else {
            Issue.record("the seed snapshot did not decode as a snapshot")
            return
        }
        #expect(decoded.tasks.map(\.id) == snapshot.tasks.map(\.id))
    }
}
