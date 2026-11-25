import CmuxNextCompat
import CmuxNextSettings
import Foundation
import Testing

/// Import Sound… and Custom Sound… (https://github.com/manaflow-ai/cmux/issues/55219): a file lands
/// in cmux's own sound folder under its own name, the same file again keeps that name, another file
/// with the same name gets "Name 2", a name a system folder already plays is never shadowed, a file
/// NSSound cannot play is refused, and the player finds each kept file by its name.
struct NotificationSoundLibraryTests {
    private let root: URL
    private let user: URL
    private let system: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "notification-sounds-\(UUID().uuidString)", directoryHint: .isDirectory)
        user = root.appending(path: "Application Support/cmux-next/com.example.cmux/Sounds", directoryHint: .isDirectory)
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
        #expect(try library.importSound(from: file("Chime.mp3", "three")) == "Chime 3", "another extension never shares a kept name")
        #expect(library.names() == ["Chime", "Chime 2", "Chime 3", "Glass", "Glass 2"])
        #expect(library.customFiles() == ["Chime": user.appending(path: "Chime.wav"), "Chime 2": user.appending(path: "Chime 2.wav"),
                                          "Chime 3": user.appending(path: "Chime 3.mp3"), "Glass 2": user.appending(path: "Glass 2.wav")],
                "only the kept files are loaded by path; Glass stays the system's")
        #expect(try String(contentsOf: user.appending(path: "Chime 2.wav"), encoding: .utf8) == "two", "the copy is the picked file")
    }

    @Test func theDefaultFolderSitsBesideTheSettingsFile() {
        // Stable and Nightly share cmux-next.json, so the files its sound names refer to must be shared too.
        let folder = NotificationSoundLibrary.defaultUserDirectory
        #expect(folder.lastPathComponent == "sounds")
        #expect(folder.deletingLastPathComponent().standardizedFileURL == BuildStatePaths.current.configDirectory.standardizedFileURL,
                "\(folder.path)")
        #expect(!folder.path.contains("/Library/Sounds"), "never the shared ~/Library/Sounds")
    }

    @Test func noneAndDefaultAreNeverAnImportedName() throws {
        // They are settings values: "none" plays nothing and "default" the system alert.
        let library = NotificationSoundLibrary(userDirectory: user, otherDirectories: [system])
        #expect(try library.importSound(from: file("none.wav", "a")) == "none 2")
        #expect(try library.importSound(from: file("default.aiff", "b")) == "default 2")
    }

    @Test func aFileNSSoundCannotPlayIsRefused() throws {
        let library = NotificationSoundLibrary(userDirectory: user, otherDirectories: [system])
        #expect(throws: NotificationSoundLibrary.ImportRefusal.self) { try library.importSound(from: try file("notes.txt", "x")) }
        #expect(!FileManager.default.fileExists(atPath: user.appending(path: "notes.txt").path))
    }
}
