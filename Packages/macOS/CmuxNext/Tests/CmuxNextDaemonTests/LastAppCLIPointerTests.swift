@testable import CmuxNextDaemon
import Foundation
import Testing

/// The "last opened app" pointer is never claimed by a copy that is gone at the next restart or eject: App
/// Translocation's mirror or a disk image (Leo, 2026-11-08, Mac setup: copies opened from the disk image).
struct LastAppCLIPointerTests {
    private static func home() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appending(path: "last-app-cli-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    @Test func passingCopiesAreTranslocatedOrReadOnly() throws {
        #expect(LastAppCLIPointer.isPassing("/private/var/folders/xy/T/AppTranslocation/1234/d/cmux NIGHTLY.app/Contents/Resources/bin/cmux"))
        #expect(LastAppCLIPointer.isPassing("/bin/ls"), "the sealed system volume is read-only, as a disk image is")
        let home = try Self.home()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(!LastAppCLIPointer.isPassing(home.path))
    }

    @Test func aReadOnlyCLIIsNeverPublished() throws {
        let home = try Self.home()
        defer { try? FileManager.default.removeItem(at: home) }
        let pointer = LastAppCLIPointer(userHome: home)
        #expect(!pointer.publish(cliPath: "/bin/ls"), "an executable on a read-only volume")
        #expect(!FileManager.default.fileExists(atPath: pointer.file.path))
        let cli = home.appending(path: "cmux")
        try Data("#!/bin/sh\n".utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        #expect(pointer.publish(cliPath: cli.path))
        #expect(try String(contentsOf: pointer.file, encoding: .utf8) == cli.path + "\n")
    }

    /// A dev shim installed before NEXT's own folder reads only classic's pointer: one already there follows the app,
    /// and a Mac without one never gets one (goals/next-store-out-of-classic).
    @Test func classicsPointerIsKeptCurrentOnlyWhereItIs() throws {
        let home = try Self.home()
        defer { try? FileManager.default.removeItem(at: home) }
        let pointer = LastAppCLIPointer(userHome: home)
        let cli = home.appending(path: "cmux")
        try Data("#!/bin/sh\n".utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        #expect(pointer.publish(cliPath: cli.path))
        #expect(!FileManager.default.fileExists(atPath: pointer.legacyFile.path))

        try FileManager.default.createDirectory(at: pointer.legacyFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("/old/cmux NIGHTLY.app/Contents/Resources/bin/cmux\n".utf8).write(to: pointer.legacyFile)
        #expect(pointer.publish(cliPath: cli.path))
        #expect(try String(contentsOf: pointer.legacyFile, encoding: .utf8) == cli.path + "\n")
        #expect(try String(contentsOf: pointer.file, encoding: .utf8) == cli.path + "\n")
    }
}
