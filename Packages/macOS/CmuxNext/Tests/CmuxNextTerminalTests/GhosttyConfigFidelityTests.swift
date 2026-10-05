import Foundation
import Testing
@testable import CmuxNextTerminal

/// R92: Ghostty config keys the embedder implements reach cmux the way they
/// reach Ghostty.app (plans/cmux-next/ghostty-config-inventory.md).
@Suite struct GhosttyConfigFidelityTests {
    /// `bell-features`: Ghostty's default (`attention,title`) plays no
    /// system sound; cmux used to beep on every BEL.
    @Test func bellFollowsBellFeatures() {
        let defaults = GhosttyBellSettings(configText: "")
        #expect(defaults.effects(appIsActive: true).isEmpty)
        #expect(defaults.effects(appIsActive: false) == [.requestAttention])

        let loud = GhosttyBellSettings(configText: "bell-features = system,audio,no-attention\nbell-audio-path = /tmp/bell.aiff\nbell-audio-volume = 0.25\n")
        #expect(loud.effects(appIsActive: false) == [.systemBeep, .playSound(path: "/tmp/bell.aiff", volume: 0.25)])

        let quiet = GhosttyBellSettings(configText: "bell-features = no-attention,no-title\n")
        #expect(quiet.effects(appIsActive: false).isEmpty)
    }

    /// The files libghostty read (config, includes, themes), for the
    /// Settings source and the reload watcher.
    @Test func loadedFilesListTheConfigAndItsIncludes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-gcf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let include = dir.appendingPathComponent("extra")
        try "font-size = 15\n".write(to: include, atomically: true, encoding: .utf8)
        let main = dir.appendingPathComponent("config")
        try "config-file = \(include.path)\n".write(to: main, atomically: true, encoding: .utf8)
        let files = GhosttyRuntime.loadedFiles(configFile: main.path)
        #expect(files.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
            == [main, include].map { $0.resolvingSymlinksInPath().path })
    }
}
