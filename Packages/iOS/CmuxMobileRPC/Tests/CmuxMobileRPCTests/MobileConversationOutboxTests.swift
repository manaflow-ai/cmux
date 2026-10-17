import Foundation
import Testing

@testable import CmuxMobileRPC

@Suite struct MobileConversationOutboxTests {
    @Test func interruptedDeliveryRemainsPendingAfterRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("commands.json")
        let original = try MobileConversationOutbox(fileURL: file)
        let command = Data(#"{"text":"run the migration"}"#.utf8)
        try await original.stage(commandID: "command-1", sessionID: "session-1", command: command)

        let reopened = try MobileConversationOutbox(fileURL: file)
        let pending = await reopened.pending(sessionID: "session-1")
        #expect(pending.count == 1)
        #expect(pending.first?.command == command)
        #expect(pending.first?.receipt == nil)
        #expect(await reopened.pending(sessionID: "other-session").isEmpty)
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
    }

    @Test func commandIdentityCannotBeReusedForDifferentWork() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = try MobileConversationOutbox(fileURL: directory.appendingPathComponent("commands.json"))
        let first = Data("first".utf8)
        try await outbox.stage(commandID: "id", sessionID: "session", command: first)
        try await outbox.stage(commandID: "id", sessionID: "session", command: first)
        await #expect(throws: (any Error).self) {
            try await outbox.stage(commandID: "id", sessionID: "session", command: Data("second".utf8))
        }
        await #expect(throws: (any Error).self) {
            try await outbox.stage(commandID: "id", sessionID: "other-session", command: first)
        }
        #expect(await outbox.pending(sessionID: "session").count == 1)
    }

    @Test func uncertainReceiptIsRetainedUntilAnAuthoritativeSettlement() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("commands.json")
        let outbox = try MobileConversationOutbox(fileURL: file)
        try await outbox.stage(commandID: "id", sessionID: "session", command: Data("prompt".utf8))
        try await outbox.record(commandID: "id", receipt: Data("uncertain".utf8), settled: false)
        let reopened = try MobileConversationOutbox(fileURL: file)
        #expect(await reopened.pending(sessionID: "session").first?.receipt == Data("uncertain".utf8))
        try await reopened.record(commandID: "id", receipt: Data("applied".utf8), settled: true)
        let final = try MobileConversationOutbox(fileURL: file)
        #expect(await final.pending(sessionID: "session").isEmpty)
    }

    @Test func lateTimeoutCannotUndoAReconciledReceipt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("commands.json")
        let store = try MobileConversationOutbox(fileURL: file)
        try await store.stage(commandID: "id", sessionID: "session", command: Data("prompt".utf8))
        try await store.record(commandID: "id", receipt: Data("applied".utf8), settled: true)
        try await store.record(commandID: "id", receipt: Data("uncertain".utf8), settled: false)
        #expect(await store.pending(sessionID: "session").isEmpty)
        let reopened = try MobileConversationOutbox(fileURL: file)
        #expect(await reopened.pending(sessionID: "session").isEmpty)
    }

    @Test func corruptOutboxFailsClosedInsteadOfForgettingUncertainWork() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("commands.json")
        try Data("interrupted record".utf8).write(to: file)
        #expect(throws: (any Error).self) {
            _ = try MobileConversationOutbox(fileURL: file)
        }
    }
}
