import CmuxNextSettings
import Foundation
import Testing

/// Import Sound…: a file lands in the user's sound folder under its own name, the same file again
/// keeps that name, another file with the same name gets "Name 2", a name a system folder already
/// plays is never shadowed, and a file NSSound cannot play is refused.
struct NotificationSoundLibraryTests {
    private let root: URL
    private let user: URL
    private let system: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "notification-sounds-\(UUID().uuidString)", directoryHint: .isDirectory)
        user = root.appending(path: "Library/Sounds", directoryHint: .isDirectory)
        system = root.appending(path: "System/Sounds", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: system, withIntermediateDirectories: true)
        try Data("system glass".utf8).write(to: system.appending(path: "Glass.aiff"))
    }

    private func file(_ name: String, _ contents: String) throws -> URL {
        let url = root.appending(path: "downloads/\(UUID().uuidString)/\(name)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    @Test func importsKeepTheirNameAndNeverOverwrite() throws {
        let library = NotificationSoundLibrary(userDirectory: user, otherDirectories: [system])
        let chime = try file("Chime.wav", "one")
        #expect(try library.importSound(from: chime) == "Chime")
        #expect(try library.importSound(from: chime) == "Chime", "the same file again keeps its name")
        #expect(try library.importSound(from: file("Chime.wav", "two")) == "Chime 2", "another file never overwrites")
        #expect(try library.importSound(from: file("Glass.wav", "mine")) == "Glass 2", "a system sound's name is not shadowed")
        #expect(library.names() == ["Chime", "Chime 2", "Glass", "Glass 2"])
    }

    @Test func aFileNSSoundCannotPlayIsRefused() throws {
        let library = NotificationSoundLibrary(userDirectory: user, otherDirectories: [system])
        #expect(throws: NotificationSoundLibrary.ImportRefusal.self) { try library.importSound(from: try file("notes.txt", "x")) }
        #expect(!FileManager.default.fileExists(atPath: user.appending(path: "notes.txt").path))
    }
}
