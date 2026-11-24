@testable import CmuxNextBrowser
import Foundation
import Testing

/// What a reader of the draw-on-input mode learns from it (`CEFDrawOnInput.keyFrames`, `hasKeyFrames`), and when the
/// runtime makes the one instance that holds the fork's calls (`CEFRuntime.drawOnInput`).
///
/// The counter is how the typing bench tells an arm that drew keys at once from one that only stored the toggle: a
/// fork at API 35 built before `cmux_shim_draw_on_input_key_frames` has the opt-in call and no counter, and a page
/// the fork does not draw keys for has no count of its own. Neither may read as "zero frames", which is the number a
/// mode that ran and did nothing would report (`CEFDrawOnInput.keyFrames`, and cmux#45709's labelling trap).
@MainActor @Suite struct CEFDrawOnInputKeyFramesTests {
    /// `cmux_shim_draw_on_input_key_frames` as the fork answers it: a count per browser, -1 for a browser it has no
    /// count for. `asked` records every browser the reader asked about.
    final class Frames {
        var counts: [Int32: Int32]
        var asked: [Int32] = []
        init(_ counts: [Int32: Int32]) { self.counts = counts }
        func count(_ browser: Int32) -> Int32 {
            asked.append(browser)
            return counts[browser] ?? -1
        }
    }

    let chat = URL(string: "cmux-page://cmux.agent/?session=s1")
    let web = URL(string: "https://example.com/")
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "cef-draw-on-input-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func make(_ fork: CEFDrawOnInputTests.Fork, frames: Frames?) -> CEFDrawOnInput {
        CEFDrawOnInput(call: { fork.call($0, $1) },
                       keyFrames: frames.map { frames in { frames.count($0) } },
                       isOn: { true })
    }

    /// An engine with the opt-in call and no counter reports no frames at all, for any chat it draws keys for: a
    /// reader must not take a missing call for a mode that drew nothing.
    @Test func anEngineWithoutTheCounterReportsNoFramesRatherThanZero() {
        let draw = make(CEFDrawOnInputTests.Fork(), frames: nil)
        draw.addressChanged(browser: 7, url: chat)
        #expect(draw.drawing == [7])
        #expect(!draw.hasKeyFrames)
        #expect(draw.keyFrames.isEmpty)
    }

    /// The count covers the chats the fork draws keys for, and only those: a page that never opted in is not asked,
    /// and one that left the chat stops being counted.
    @Test func theCountCoversTheChatsTheForkDrawsFor() {
        let frames = Frames([7: 3, 8: 5])
        let draw = make(CEFDrawOnInputTests.Fork(), frames: frames)
        draw.addressChanged(browser: 7, url: chat)
        draw.addressChanged(browser: 8, url: web)
        #expect(draw.hasKeyFrames)
        #expect(draw.keyFrames == [7: 3])
        #expect(frames.asked == [7], "the reader asked about a page the fork does not draw keys for: \(frames.asked)")
        draw.addressChanged(browser: 7, url: web)
        #expect(draw.keyFrames.isEmpty)
    }

    /// Zero frames is a count (the mode ran and drew none); -1 is the engine saying it has none, and that browser is
    /// left out of the map instead of reported as zero.
    @Test func aBrowserTheEngineHasNoCountForIsLeftOut() {
        let frames = Frames([7: 0])
        let draw = make(CEFDrawOnInputTests.Fork(), frames: frames)
        draw.addressChanged(browser: 7, url: chat)
        draw.addressChanged(browser: 9, url: chat)
        #expect(draw.drawing == [7, 9])
        #expect(draw.keyFrames == [7: 0])
        #expect(Set(frames.asked) == [7, 9])
    }

    /// The shim's counter reaches the mode only from fork API 35 on, and a shim without that symbol leaves it nil.
    @Test(arguments: [(35 as Int32, true, true), (35, false, false), (34, true, false)])
    func theCounterComesFromTheShimOnlyAtTheForkAPI(apiVersion: Int32, shimHasCounter: Bool, reports: Bool) throws {
        let draw = CEFDrawOnInput(shim: try DrawOnInputShim.library(counter: shimHasCounter), apiVersion: apiVersion)
        #expect(draw.hasKeyFrames == reports)
        #expect(draw.keyFrames.isEmpty, "no page opted in, so there is nothing to count")
    }

    /// The runtime keeps one draw-on-input only once the shim is there: it binds the fork's calls at init, so one
    /// made before the library loaded holds no call, and keeping that would leave the mode inert for the whole
    /// process however the setting reads (an early `debug.cef`, which the typing bench does make, is such a read).
    @Test func aDrawOnInputMadeBeforeTheShimLoadedIsNotKept() {
        let runtime = CEFRuntime(libraryLoader: { _ in .failure(.notEmbedded) }, storage: CEFProfileStorage(root: root))
        let early = runtime.drawOnInput
        #expect(!early.hasKeyFrames)
        #expect(runtime.drawOnInput !== early, "the runtime kept a draw-on-input made with no shim: the mode stays inert for this process")
    }

    /// With the shim there, the mode is made once and that one instance holds the fork's calls (the browsers it
    /// opted in must not be forgotten by a second read).
    @Test func theDrawOnInputMadeWithTheShimIsTheOneTheProcessUses() throws {
        let runtime = CEFRuntime(shim: try DrawOnInputShim.library(counter: true), storage: CEFProfileStorage(root: root))
        let made = runtime.drawOnInput
        #expect(made.hasKeyFrames, "the stand-in shim reports fork API 35 and the counter: the test proves nothing without it")
        #expect(runtime.drawOnInput === made)
    }
}

/// Stand-in shim at fork API 35: `cmux_shim_browser_set_draw_on_input` takes every call, and the key-frame counter
/// is there only with `counter` (a fork built before it exports no such symbol). Every other function returns 0.
private nonisolated enum DrawOnInputShim {
    static func library(counter: Bool) throws -> CEFShimLibrary {
        let setDrawOnInput: @convention(c) (Int32, Int32) -> Int32 = { _, _ in 1 }
        let keyFrames: @convention(c) (Int32) -> Int32 = { _ in 0 }
        let forkAPIVersion: @convention(c) () -> Int32 = { 35 }
        let nothing: @convention(c) () -> Int = { 0 }
        return try CEFShimLibrary.resolving { name in
            switch name {
            case "cmux_shim_browser_set_draw_on_input": unsafeBitCast(setDrawOnInput, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_draw_on_input_key_frames": counter ? unsafeBitCast(keyFrames, to: UnsafeMutableRawPointer.self) : nil
            case "cmux_shim_fork_api_version": unsafeBitCast(forkAPIVersion, to: UnsafeMutableRawPointer.self)
            default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
            }
        }
    }
}
