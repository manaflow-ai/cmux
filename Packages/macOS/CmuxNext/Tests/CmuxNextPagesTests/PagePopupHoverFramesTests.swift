import AppKit
import CmuxNextCompat
import CmuxNextDesign
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import CmuxNextWakeups
import Foundation
import Testing

/// A page's popup past the window's edge gets the App's frame-aligned hover input (feature
/// `pointerFrameHover`): ``WebUIHost`` hands it to each page it opens, and the page's
/// popup host (made on the page's first popup op) passes it to the popup's rows. Without it, every
/// row move would still send the page a `highlight` at once.
@MainActor
struct PagePopupHoverFramesTests {
    private let root: URL
    private let descriptor = PageDescriptor(id: "test.popup-hover-frames", resource: "popup-hover-frames",
                                            processGroup: .solo, namespaces: [])

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("popup-hover-frames-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
    }

    private func makeHost(_ hoverFrameInput: FrameInputCoalescers?) -> WebUIHost {
        WebUIHost(chromium: nil, openPanel: nil, memory: QuietMemoryRegistry(),
                  deadlines: LifecycleDeadlineRig.never, hoverFrameInput: hoverFrameInput)
    }

    private static let menu: [String: Any] = [
        "items": [["id": "a", "label": "A"], ["id": "b", "label": "B"]],
        "anchor": ["left": 10, "top": 10, "right": 120, "bottom": 30], "width": 140,
    ]

    @Test func aPageOpenedByTheHostHandsTheHoverFramesToItsPopup() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let frames = FrameInputCoalescers()
        let host = makeHost(frames)
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        defer { host.close(view) }
        #expect(view.popupHoverFrameInput === frames)
        // The page's first popup op makes its popup host (an update of a menu not shown changes nothing).
        _ = view.popup(PageNativeOp.popupUpdate, params: Self.menu)
        let popup = try #require(view.popupHost)
        #expect(popup.hoverFrameInput === frames)
    }

    @Test func withTheFeatureOffThePopupHoversEachMove() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let host = makeHost(nil)
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        defer { host.close(view) }
        _ = view.popup(PageNativeOp.popupUpdate, params: Self.menu)
        let popup = try #require(view.popupHost)
        #expect(popup.hoverFrameInput == nil)
    }

    @Test func settingTheInputLaterReachesAPopupAlreadyMade() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let host = makeHost(nil)
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        defer { host.close(view) }
        _ = view.popup(PageNativeOp.popupUpdate, params: Self.menu)
        let frames = FrameInputCoalescers()
        view.popupHoverFrameInput = frames  // a pooled page claimed after its popup was made
        #expect(view.popupHost?.hoverFrameInput === frames)
    }
}
