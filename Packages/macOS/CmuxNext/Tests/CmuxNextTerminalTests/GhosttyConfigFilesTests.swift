@testable import CmuxNextTerminal
import Darwin
import Foundation
import GhosttyNextKit
import Testing

/// The launch's in-memory Ghostty config files (p08-startup-026): ``GhosttyConfigFiles/read(_:reader:)`` takes
/// the files libghostty's own load takes, in its order, or declines (nil) wherever libghostty would do more than
/// read plain files; loaded from memory, they make the config, the diagnostics and the loaded files the disk
/// path makes.
@MainActor @Suite("Ghostty config files read at launch", .serialized)
struct GhosttyConfigFilesTests {
    // MARK: The read, on a fake file system

    /// A file system of `files` (path to text); `directories` are there but not files.
    static func reader(_ files: [String: String], directories: Set<String> = []) -> GhosttyConfigFiles.Reader {
        GhosttyConfigFiles.Reader(entry: { path in
            if directories.contains(path) { return .other }
            return files[path].map { .file(Data($0.utf8)) } ?? .missing
        }, resolve: { path in
            files[path] != nil || directories.contains(path) ? .resolved(path) : .missing
        })
    }

    static let defaults = ["/h/.config/ghostty/config", "/h/.config/ghostty/config.ghostty",
                           "/h/AS/com.mitchellh.ghostty/config", "/h/AS/com.mitchellh.ghostty/config.ghostty"]

    @Test func topLevelFilesThenTheirIncludesBreadthFirst() throws {
        let files = try #require(GhosttyConfigFiles.read(
            .init(defaults: Self.defaults, classic: "/h/AS/com.cmuxterm.app/config.ghostty", home: "/h"),
            reader: Self.reader([
                "/h/.config/ghostty/config.ghostty": "config-file = a\nconfig-file = ?missing\nfont-size = 13\n",
                "/h/AS/com.mitchellh.ghostty/config": "config-file = \"~/b\"\n",
                "/h/AS/com.cmuxterm.app/config.ghostty": "font-size = 15\n",
                "/h/.config/ghostty/a": "config-file = ../ghostty/c\n",
                "/h/b": "theme = x\n",
                "/h/.config/ghostty/c": "",
            ])))
        // libghostty: every top-level file first (classic's layer last), then the `config-file` list as it grows.
        #expect(files.paths == ["/h/.config/ghostty/config.ghostty", "/h/AS/com.mitchellh.ghostty/config",
                                "/h/AS/com.cmuxterm.app/config.ghostty", "/h/.config/ghostty/a", "/h/b",
                                "/h/.config/ghostty/c"])
    }

    @Test func theOverrideIsReadAloneWithItsIncludes() throws {
        let files = try #require(GhosttyConfigFiles.read(.init(override: "/t/config", defaults: Self.defaults, home: "/h"),
                                                         reader: Self.reader(["/t/config": "config-file = inc\n", "/t/inc": "x = 1\n",
                                                                              "/h/.config/ghostty/config": "font-size = 9\n"])))
        #expect(files.paths == ["/t/config", "/t/inc"])
    }

    @Test func declinesWhereLibghosttyDoesMoreThanRead() {
        let locations = GhosttyConfigFiles.Locations(defaults: Self.defaults, home: "/h")
        let top = Self.defaults[1]
        let declined: [(String, [String: String], Set<String>)] = [
            ("no config: libghostty writes its template", [:], []),
            ("an empty default file", [top: ""], []),
            ("a default file that is a directory", [:], [top]),
            ("a missing required include", [top: "config-file = gone\n"], []),
            ("an include cycle", [top: "config-file = a\n", "/h/.config/ghostty/a": "config-file = a\n"], []),
            ("an empty value clears the list", [top: "config-file = a\nconfig-file =\n", "/h/.config/ghostty/a": ""], []),
            ("the key with no value", [top: "config-file\n"], []),
            ("an include that is a directory", [top: "config-file = ?d\n"], ["/h/.config/ghostty/d"]),
            ("a line longer than libghostty reads", [top: "config-file = " + String(repeating: "a", count: 5000) + "\n"], []),
        ]
        for (name, files, directories) in declined {
            #expect(GhosttyConfigFiles.read(locations, reader: Self.reader(files, directories: directories)) == nil, "\(name)")
        }
        #expect(GhosttyConfigFiles.read(.init(override: "relative/config", home: "/h"), reader: Self.reader(["relative/config": "a = 1"])) == nil)
    }

    @Test func valuesAreReadAsLibghosttysLineReaderReadsThem() throws {
        let top = Self.defaults[1]
        let text = "\u{FEFF}# config-file = commented\n  config-file\t=  \"?quoted\"  \r\nconfig-file = ?\nconfig-file = /abs/x\nconfig-file=sub/./y/../z\n"
        let files = try #require(GhosttyConfigFiles.read(.init(defaults: Self.defaults, home: "/h"), reader: Self.reader([
            top: text, "/abs/x": "", "/h/.config/ghostty/sub/z": "",
        ])))
        // `?quoted` is optional and missing; `?` alone is ignored; a missing relative path is made absolute as written.
        #expect(files.paths == [top, "/abs/x", "/h/.config/ghostty/sub/z"])
    }

    // MARK: Parity with libghostty's own reads

    /// One config graph, loaded the way the runtime loads it, from the disk and from memory: the same values,
    /// libghostty messages, unsupported keys and keybind actions with their files and lines, and loaded files.
    @Test func diagnosticsAreIdenticalOnBothPaths() async throws {
        _ = GhosttyRuntime.shared  // runs ghostty_init, which config_new needs
        let directory = FileManager.default.temporaryDirectory.appending(path: "cn-ghostty-files-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory.appending(path: "parts"), withIntermediateDirectories: true)
        let main = directory.appending(path: "config")
        try Data("font-size = 14\nconfig-file = parts/keys\nconfig-file = ?parts/missing\nnot-a-real-key = 1\nmaximize = true\n".utf8).write(to: main)
        try Data("keybind = cmd+i=inspector:toggle\nconfig-file = ../extra\nfont-size = nope\n".utf8)
            .write(to: directory.appending(path: "parts/keys"))
        try Data("scrollbar = never\nfont-size = 16\n".utf8).write(to: directory.appending(path: "extra"))

        let key = GhosttyRuntime.configOverrideKey
        let previous = getenv(key).map { String(cString: $0) }
        setenv(key, main.path, 1)
        defer { if let previous { setenv(key, previous, 1) } else { unsetenv(key) } }

        let files = try #require(GhosttyConfigFiles.read(.current()))
        #expect(files.paths.count == 3)
        var diskMessages: [String] = [], memoryMessages: [String] = []
        var diskOpacity = 1.0, memoryOpacity = 1.0
        let disk = try #require(GhosttyRuntime.loadConfig(diagnostics: &diskMessages, opacity: &diskOpacity))
        defer { ghostty_config_free(disk) }
        let memory = try #require(GhosttyRuntime.loadConfig(diagnostics: &memoryMessages, opacity: &memoryOpacity, files: files))
        defer { ghostty_config_free(memory) }

        #expect(!diskMessages.isEmpty)
        #expect(memoryMessages == diskMessages)
        #expect(memoryOpacity == diskOpacity)
        var diskSize: Float = 0, memorySize: Float = 0
        #expect(GhosttyRuntime.configGet(disk, &diskSize, key: "font-size"))
        #expect(GhosttyRuntime.configGet(memory, &memorySize, key: "font-size"))
        #expect(memorySize == diskSize && diskSize == 16)

        let diskSnapshot = GhosttyRuntime.snapshot(of: disk)
        let memorySnapshot = GhosttyRuntime.snapshot(of: memory, memory: files.paths)
        #expect(memorySnapshot.files == diskSnapshot.files)
        #expect(Array(diskSnapshot.files.prefix(3)) == files.paths)
        #expect(memorySnapshot == diskSnapshot)
        let diskFindings = await diskSnapshot.diagnostics(), memoryFindings = await memorySnapshot.diagnostics()
        #expect(memoryFindings == diskFindings)
        #expect(diskFindings.contains { $0.kind == .key && $0.name == "scrollbar" })
        #expect(diskFindings.contains { $0.kind == .keybindAction && $0.name == "inspector" })
    }
}
