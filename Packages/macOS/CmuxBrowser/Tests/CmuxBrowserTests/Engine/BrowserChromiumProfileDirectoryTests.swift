import Foundation
import Testing
@testable import CmuxBrowser

@Suite struct BrowserChromiumProfileDirectoryTests {
    @Test func removesOnlyTheOwnedSession() throws {
        let builder = BrowserChromiumProfileDirectory()
        let profileID = UUID()
        let surfaceID = UUID()
        let firstSession = builder.url(
            profileID: profileID,
            surfaceID: surfaceID,
            sessionID: UUID()
        )
        let secondSession = builder.url(
            profileID: profileID,
            surfaceID: surfaceID,
            sessionID: UUID()
        )
        let profileDirectory = firstSession
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let surfaceDirectory = firstSession.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: firstSession, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondSession, withIntermediateDirectories: true)
        defer {
            try? builder.removeSessionDirectoryIfOwned(firstSession)
            try? builder.removeSessionDirectoryIfOwned(secondSession)
            try? FileManager.default.removeItem(at: profileDirectory)
        }

        try builder.removeSessionDirectoryIfOwned(firstSession)

        #expect(!FileManager.default.fileExists(atPath: firstSession.path))
        #expect(FileManager.default.fileExists(atPath: secondSession.path))

        try builder.removeSessionDirectoryIfOwned(secondSession)

        #expect(!FileManager.default.fileExists(atPath: secondSession.path))
        #expect(!FileManager.default.fileExists(atPath: surfaceDirectory.path))
        #expect(!FileManager.default.fileExists(atPath: profileDirectory.path))
    }

    @Test func refusesToRemoveDirectoryOutsideOwnedUUIDHierarchy() throws {
        let builder = BrowserChromiumProfileDirectory()
        let outsideDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-chromium-cleanup-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outsideDirectory) }

        try builder.removeSessionDirectoryIfOwned(outsideDirectory)

        #expect(FileManager.default.fileExists(atPath: outsideDirectory.path))
    }
}
