import AppKit
@testable import CmuxNextBrowser
import Testing

/// Task 050 of plans/cmux-next/chrome-parity/p01-process.md: drags from outside into a hosted page.
/// The page view (or the pane's host view for it) is the drag's destination: it sends DragTarget
/// enter, over, leave and drop with the drag's files, text and link, and answers AppKit with the
/// last operation the renderer chose (DRAG_OPERATION), as Chrome's `WebDragDest` does.
@MainActor
@Suite struct ChromiumHostPageViewDragTests {
    /// Records each call; `browser` is the shown tab's.
    final class Recorder: ChromiumHostDragWire {
        var dragBrowser: Int32?
        var sent: [(event: ChromiumHostDragEvent, browser: Int32)] = []

        init(browser: Int32? = 7) {
            dragBrowser = browser
        }

        func send(_ event: ChromiumHostDragEvent, browser: Int32) {
            sent.append((event, browser))
        }

        var events: [ChromiumHostDragEvent] { sent.map(\.event) }
    }

    static let files = ChromiumHostDropData(files: ["/tmp/a.png", "/tmp/b.pdf"])
    static let at = ChromiumHostDragPoint(x: 40, y: 30)

    static func destination(_ wire: Recorder) -> ChromiumHostDragDestination {
        let destination = ChromiumHostDragDestination()
        destination.wire = wire
        return destination
    }

    // MARK: The destination

    @Test func anEnterSendsTheDataAndOffersCopyUntilThePageAnswers() {
        let wire = Recorder()
        let destination = Self.destination(wire)
        let entered = destination.entered(Self.files, at: Self.at, allowed: [.copy, .link, .move], modifiers: 1 << 1)
        #expect(entered == .copy, "the page has not seen the drag yet: the drop is not refused")
        #expect(wire.events == [.enter(Self.files, Self.at, allowed: 1 | 2 | 16, modifiers: 1 << 1)])
        #expect(wire.sent.first?.browser == 7)

        let over = ChromiumHostDragPoint(x: 41, y: 31)
        #expect(destination.updated(at: over, allowed: .copy, modifiers: 0) == .copy)
        #expect(wire.events.last == .over(over, allowed: 1, modifiers: 0))
    }

    @Test func updatesReturnTheRenderersLastAnswer() {
        let wire = Recorder()
        let destination = Self.destination(wire)
        _ = destination.entered(Self.files, at: Self.at, allowed: .every, modifiers: 0)
        // A drop zone that takes a move (dropEffect "move"), then a part of the page that takes none.
        destination.answered(browser: 7, operation: 16)
        #expect(destination.updated(at: Self.at, allowed: .every, modifiers: 0) == .move)
        destination.answered(browser: 7, operation: 0)
        #expect(destination.updated(at: Self.at, allowed: .every, modifiers: 0) == [],
                "AppKit refuses the drop where the page takes none")
        destination.answered(browser: 7, operation: 1)
        #expect(destination.updated(at: Self.at, allowed: .every, modifiers: 0) == .copy)
        #expect(wire.events.count == 4, "every update is one DragTarget over, even at a resting point")
    }

    @Test func anAnswerForAnotherBrowserOrAfterTheDragChangesNothing() {
        let wire = Recorder()
        let destination = Self.destination(wire)
        _ = destination.entered(Self.files, at: Self.at, allowed: .copy, modifiers: 0)
        destination.answered(browser: 8, operation: 0)
        #expect(destination.operation == .copy, "another tab's answer is not this drag's")
        destination.exited()
        destination.answered(browser: 7, operation: 1)
        #expect(destination.operation == [], "a late answer does not revive an ended drag")
        #expect(destination.browser == nil)
    }

    @Test func anExitSendsOneLeave() {
        let wire = Recorder()
        let destination = Self.destination(wire)
        _ = destination.entered(Self.files, at: Self.at, allowed: .copy, modifiers: 0)
        destination.exited()
        destination.exited()
        #expect(wire.events == [.enter(Self.files, Self.at, allowed: 1, modifiers: 0), .leave],
                "draggingEnded after draggingExited sends no second leave")
    }

    @Test func aDropSendsTheDropAndNoLeave() {
        let wire = Recorder()
        let destination = Self.destination(wire)
        _ = destination.entered(Self.files, at: Self.at, allowed: .copy, modifiers: 0)
        let drop = ChromiumHostDragPoint(x: 50, y: 60)
        #expect(destination.dropped(at: drop, modifiers: 1 << 7))
        destination.exited()
        #expect(wire.events.last == .drop(drop, modifiers: 1 << 7))
        #expect(!wire.events.contains(.leave), "the session's draggingEnded after the drop is no leave")
        #expect(!destination.dropped(at: drop, modifiers: 0), "no drag, no drop")
    }

    @Test func countsTellDragTargetDropsAndTheirAnswers() {
        let wire = Recorder()
        let destination = Self.destination(wire)
        _ = destination.entered(Self.files, at: Self.at, allowed: .copy, modifiers: 0)
        destination.answered(browser: 7, operation: 1)
        destination.answered(browser: 8, operation: 1)
        #expect(destination.dropped(at: Self.at, modifiers: 0))
        destination.answered(browser: 7, operation: 1)
        #expect(destination.counts == ChromiumHostDragCounts(enters: 1, drops: 1, answers: 1),
                "another tab's answer and a late one are not this drag's")

        let refused = Self.destination(Recorder(browser: nil))
        _ = refused.entered(Self.files, at: Self.at, allowed: .copy, modifiers: 0)
        #expect(!refused.dropped(at: Self.at, modifiers: 0))
        #expect(refused.counts == ChromiumHostDragCounts(), "a refused drag sends no DragTarget call")
    }

    @Test func noBrowserNoWireOrNoDataRefusesTheDrag() {
        let none = Recorder(browser: nil)
        #expect(Self.destination(none).entered(Self.files, at: Self.at, allowed: .copy, modifiers: 0) == [])
        #expect(none.sent.isEmpty)

        let empty = Recorder()
        let destination = Self.destination(empty)
        #expect(destination.entered(ChromiumHostDropData(), at: Self.at, allowed: .copy, modifiers: 0) == [])
        #expect(destination.updated(at: Self.at, allowed: .copy, modifiers: 0) == [])
        #expect(empty.sent.isEmpty, "a drag with nothing a page takes never reaches it")

        let unwired = ChromiumHostDragDestination()
        #expect(unwired.entered(Self.files, at: Self.at, allowed: .copy, modifiers: 0) == [])
    }

    @Test func aNewEnterEndsADragThatNeverExited() {
        let wire = Recorder()
        let destination = Self.destination(wire)
        _ = destination.entered(Self.files, at: Self.at, allowed: .copy, modifiers: 0)
        wire.dragBrowser = 9
        _ = destination.entered(Self.files, at: Self.at, allowed: .copy, modifiers: 0)
        #expect(wire.sent.map(\.browser) == [7, 7, 9])
        #expect(wire.events[1] == .leave, "the old page hears its drag leave before the new one starts")
    }

    @Test func operationsAndModifiersAreCEFsBits() {
        #expect(ChromiumHostDragDestination.mask(.every) == 0x3f)
        #expect(ChromiumHostDragDestination.mask([.copy, .move]) == 17)
        // cef_event_flags_t: shift 2, control 4, alt 8, left 16, middle 32, right 64, command 128.
        #expect(ChromiumHostDragDestination.modifiers([.shift, .command], pressedButtons: 1) == 2 | 128 | 16)
        #expect(ChromiumHostDragDestination.modifiers([.control, .option, .capsLock], pressedButtons: 2 | 4) == 4 | 8 | 1 | 64 | 32)
        #expect(ChromiumHostDragDestination.modifiers([], pressedButtons: 0) == 0)
    }

    // MARK: Data and points

    @Test func theDropDataIsReadOnceFromThePasteboard() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        func put(_ strings: [NSPasteboard.PasteboardType: String]) {
            let item = NSPasteboardItem()
            for (type, string) in strings { item.setString(string, forType: type) }
            pasteboard.clearContents()
            #expect(pasteboard.writeObjects([item]))
        }

        put([.fileURL: URL(fileURLWithPath: "/tmp/cmux drop.png").absoluteString])
        let fromFiles = ChromiumHostDropData(pasteboard: pasteboard)
        #expect(fromFiles.files == ["/tmp/cmux drop.png"])
        #expect(fromFiles.url == nil, "a file's URL is a file, not a link")

        put([.URL: "https://example.com/a?b=1", ChromiumHostDropData.urlNameType: "Example", .string: "selected words"])
        let fromLink = ChromiumHostDropData(pasteboard: pasteboard)
        #expect(fromLink == ChromiumHostDropData(text: "selected words", url: "https://example.com/a?b=1", urlTitle: "Example"))

        pasteboard.clearContents()
        #expect(ChromiumHostDropData(pasteboard: pasteboard).isEmpty)
    }

    @Test func pointsAreFromTheTopLeft() {
        #expect(ChromiumHostDragPoint(unflipped: CGPoint(x: 10.7, y: 290.2), height: 300) == ChromiumHostDragPoint(x: 10, y: 9))
    }

    // MARK: The page view and the pane

    @Test func aPageViewThatTakesInputRegistersForDrags() {
        let page = ChromiumHostPageView(frame: NSRect(x: 0, y: 0, width: 200, height: 100), inputTarget: .view)
        page.takeDrags(through: Recorder())
        #expect(Set(page.registeredDraggedTypes) == Set(ChromiumHostDropData.types))
        #expect(page.dragCounts.takesDrags, "debug.cef's page_drag says the page view takes drags")
        page.takeDrags(through: nil)
        #expect(page.registeredDraggedTypes.isEmpty)
        #expect(page.dragDestination.wire == nil)
        #expect(!page.dragCounts.takesDrags)

        // In the pane the host view takes the drag for it (CEFFileDragRelay.hostedPage).
        let behind = ChromiumHostPageView(frame: NSRect(x: 0, y: 0, width: 200, height: 100), inputTarget: .pageWindow)
        behind.takeDrags(through: Recorder())
        #expect(behind.registeredDraggedTypes.isEmpty)
        #expect(behind.dragDestination.wire != nil)
    }

    @Test func dragOperationDecodesAsAPageViewEvent() {
        #expect(CEFShimEvent(kind: 55, browser: 7, request: 0, a: 16, b: 1, s1: "", s2: "") == .pageView(browser: 7, .dragOperation(16)))
        #expect(CEFShimEvent(kind: 55, browser: 7, request: 0, a: 0, b: 0, s1: "", s2: "").browserID == 7)
    }

    /// DRAG_OPERATION reaches the page view of the pane that shows the browser, and the pane's wire
    /// sends the shim's DragTarget calls only from fork API 31.
    @Test func thePaneRoutesAnswersAndCallsTheShim() throws {
        DragSpy.reset()
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-drag-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = CEFRuntime(shim: try CEFShimLibrary.resolving(DragSpy.symbol), storage: CEFProfileStorage(root: root))
        // A pane's scheduled work reads the runtime through an unowned reference.
        _ = Unmanaged.passRetained(runtime)
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
        host.endOfTurn = { $0() }
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(tab)
        // A popup's pane: it shows by attaching its window, so no window is created here.
        host.popupWindow = 3
        runtime.register(tab, browser: 7)
        host.present(tab, in: NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300)))
        let page = ChromiumHostPageView(frame: host.hostView.bounds, inputTarget: .view)
        host.hostView.addSubview(page)
        host.hostedPageView = page
        let wire = CEFPaneDragWire(pane: host)
        page.takeDrags(through: wire)

        DragSpy.forkAPI = 30
        #expect(wire.dragBrowser == nil, "below API 31 a detached page gets no DragTarget calls")
        DragSpy.forkAPI = 31
        #expect(wire.dragBrowser == 7)

        let data = ChromiumHostDropData(files: ["/tmp/a.png"], text: "t", url: "https://example.com/", urlTitle: "E")
        #expect(page.dragDestination.entered(data, at: Self.at, allowed: .copy, modifiers: 2) == .copy)
        #expect(DragSpy.calls == ["enter 7 [/tmp/a.png] t https://example.com/ E 40,30 1 2"])
        runtime.handle(.pageView(browser: 7, .dragOperation(0)))
        #expect(page.dragDestination.operation == [], "the pane's page view took the renderer's answer")
        #expect(page.dragDestination.updated(at: Self.at, allowed: .copy, modifiers: 0) == [])
        page.dragDestination.exited()
        #expect(Array(DragSpy.calls.dropFirst()) == ["over 7 40,30 1 0", "leave 7"])
    }
}

/// Stand-in shim functions: the DragTarget calls record themselves, `fork_api_version` reports
/// `forkAPI`, `popup_window_attach` attaches; every other function does nothing and returns 0.
private nonisolated enum DragSpy {
    nonisolated(unsafe) static var calls: [String] = []
    nonisolated(unsafe) static var forkAPI: Int32 = 31

    static func reset() {
        calls = []
        forkAPI = 31
    }

    static func string(_ pointer: UnsafePointer<CChar>?) -> String {
        pointer.map { String(cString: $0) } ?? "nil"
    }

    static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        let enter: @convention(c) (Int32, UnsafePointer<UnsafePointer<CChar>?>?, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?,
                                   UnsafePointer<CChar>?, Int32, Int32, Int32, Int32) -> Int32 = {
            browser, files, count, text, url, title, x, y, allowed, modifiers in
            let paths = (0..<Int(count)).map { DragSpy.string(files?[$0]) }
            DragSpy.calls.append("enter \(browser) [\(paths.joined(separator: ","))] \(DragSpy.string(text)) \(DragSpy.string(url)) "
                + "\(DragSpy.string(title)) \(x),\(y) \(allowed) \(modifiers)")
            return 1
        }
        let over: @convention(c) (Int32, Int32, Int32, Int32, Int32) -> Int32 = { browser, x, y, allowed, modifiers in
            DragSpy.calls.append("over \(browser) \(x),\(y) \(allowed) \(modifiers)")
            return 1
        }
        let leave: @convention(c) (Int32) -> Int32 = { browser in
            DragSpy.calls.append("leave \(browser)")
            return 1
        }
        let drop: @convention(c) (Int32, Int32, Int32, Int32) -> Int32 = { browser, x, y, modifiers in
            DragSpy.calls.append("drop \(browser) \(x),\(y) \(modifiers)")
            return 1
        }
        let forkAPIVersion: @convention(c) () -> Int32 = { DragSpy.forkAPI }
        let popupWindowAttach: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32) -> Int32 = { _, _, _, _ in 1 }
        let nothing: @convention(c) () -> Int = { 0 }
        return switch name {
        case "cmux_shim_browser_drag_target_enter": unsafeBitCast(enter, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_browser_drag_target_over": unsafeBitCast(over, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_browser_drag_target_leave": unsafeBitCast(leave, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_browser_drag_target_drop": unsafeBitCast(drop, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_fork_api_version": unsafeBitCast(forkAPIVersion, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_popup_window_attach": unsafeBitCast(popupWindowAttach, to: UnsafeMutableRawPointer.self)
        default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
        }
    }
}
