import AppKit
@testable import CmuxNextTerminal
import CmuxNextWakeups
import Foundation
import GhosttyNextKit
import Testing

/// The Ghostty C API seams of p10-stability-069: one owner per kind of C memory, each with its
/// `// SAFETY:` argument. A scratch config is made, finalized, read and freed in one place
/// (``GhosttyRuntime/withScratchConfig(load:read:)``), a string key is read and copied in one place
/// (``GhosttyRuntime/configString(_:key:)``), and every text Ghostty fills for a read is copied and
/// freed by ``GhosttyTextRead``. These check that the values that cross each seam are the ones
/// Ghostty holds, on libghostty itself; run them under `--sanitize=address` too.
@MainActor @Suite(.serialized, .ghosttyStarted)
struct GhosttyPointerFreeInteropTests {
    init() {
        _ = NSApplication.shared
        _ = GhosttyRuntime.shared // ghostty_init, which ghostty_config_new needs
    }

    @Test func aScratchConfigHandsBackWhatItsReadReturned() throws {
        var loaded = 0
        // SAFETY: the closures use the handle only for their calls.
        let value = unsafe GhosttyRuntime.withScratchConfig(load: { _ in loaded += 1 }, read: { _ in 7 })
        #expect(try #require(value, "libghostty made no config") == 7)
        #expect(loaded == 1, "the load closure runs once, before the read")
    }

    @Test func aStringKeyIsCopiedOutOfItsConfig() {
        #expect(GhosttyRuntime.clipboardReadValue(configText: "clipboard-read = deny\n") == "deny")
        #expect(GhosttyRuntime.clipboardReadValue(configText: "clipboard-read = allow\n") == "allow")
        #expect(GhosttyRuntime.clipboardReadValue(configText: "") == "ask", "Ghostty's default")
    }

    @Test func thePaddingBalanceIsReadAsItsEnumName() throws {
        let balanced = try #require(GhosttyRuntime.terminalPadding(configText: "window-padding-balance = true\n"))
        let unbalanced = try #require(GhosttyRuntime.terminalPadding(configText: "window-padding-balance = false\n"))
        #expect(balanced.balanced)
        #expect(!unbalanced.balanced)
    }

    @Test func aBellAudioPathIsCopiedOutOfItsConfig() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "cmux-069-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let sound = folder.appending(path: "bell.wav")
        try Data("RIFF".utf8).write(to: sound)

        let settings = GhosttyBellSettings(configText: "bell-features = audio\nbell-audio-path = \(sound.path)\nbell-audio-volume = 0.25\n")
        #expect(settings.audioPath == sound.path)
        #expect(settings.volume == 0.25)
        #expect(settings.features.contains(.audio))
    }

    @Test func aKeybindTriggerIsReadFromAScratchConfig() {
        #expect(GhosttyRuntime.isBound("new_window", configText: "keybind = super+shift+y=new_window\n"))
    }

    /// Text reads on a live surface: the viewport, the selection (none, then all of it), the grid
    /// and the Quick Look font, each copied out before Ghostty's buffer is freed.
    @Test func surfaceReadsCopyWhatTheTerminalShows() async throws {
        let io = ScriptedTerminalIO()
        let session = TerminalSession(io: io, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 240), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            io.finish()
            window.close()
        }
        window.contentView = session.view
        session.view.frame = NSRect(x: 0, y: 0, width: 480, height: 240)
        session.view.layoutSubtreeIfNeeded()
        let view = session.surfaceView
        let surface = try #require(view.surface, "libghostty created no surface")
        let lane = try #require(view.lane)

        let marker = "cmux-069-marker"
        lane.processOutput(Data("\(marker)\r\n".utf8))
        await lane.drained()

        #expect(view.viewportText()?.contains(marker) == true)
        #expect(TerminalSelection.read(of: view) == nil, "nothing is selected yet")
        #expect(view.performBindingAction("select_all"))
        let selection = try #require(TerminalSelection.read(of: view))
        #expect(selection.text.contains(marker))
        #expect(selection.range.length >= marker.utf8.count)

        // SAFETY: the view's live surface, which the view keeps until the test ends.
        let metrics = try #require(unsafe GhosttyTextRead.gridMetrics(surface))
        #expect(metrics.columns > 0 && metrics.rows > 0)
        // SAFETY: as above.
        #expect(unsafe GhosttyTextRead.quickLookFont(surface) != nil)
    }
}
