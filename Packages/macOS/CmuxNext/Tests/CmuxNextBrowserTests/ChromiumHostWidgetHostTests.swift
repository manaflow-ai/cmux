import AppKit
@testable import CmuxNextBrowser
import Testing

/// The host's widgets with a WebContents: extension popups, the side panel,
/// DevTools docked and undocked, chrome.windows popups and InitAsPopup page popups (date and
/// datalist) show their context in cmux windows and panes, with input and geometry to the host.
@MainActor
@Suite struct ChromiumHostWidgetHostTests {
    @MainActor
    final class RecordingWire: ChromiumHostWidgetWire {
        var geometries: [(ChromiumHostWidgetID, ChromiumHostGeometry)] = []
        var dismissed: [ChromiumHostWidgetID] = []
        #if DEBUG || CMUX_BENCH_HOOKS
        var inputs: [(ChromiumHostWidgetID, ChromiumHostFrame)] = []
        func widget(_ widget: ChromiumHostWidgetID, input frame: ChromiumHostFrame) { inputs.append((widget, frame)) }
        #endif
        func widget(_ widget: ChromiumHostWidgetID, movedTo geometry: ChromiumHostGeometry) { geometries.append((widget, geometry)) }
        func dismiss(_ widget: ChromiumHostWidgetID) { dismissed.append(widget) }
    }

    /// Windows the host made and how it ordered them; nothing is ever ordered on screen.
    @MainActor
    final class Recorder {
        var views: [ChromiumHostPageView] = []
        var panels: [ChromiumHostWidgetPanel] = []
        var ordered: [(window: NSWindow, parent: NSWindow?, key: Bool)] = []
        var devToolsWindows: [CEFDevToolsWindow] = []
    }

    let primaryTop: CGFloat = 1_000
    let owner: Int32 = 7

    func makeHost(_ wire: RecordingWire, _ recorder: Recorder, ownerWindow: NSWindow? = nil,
                  customize: (inout ChromiumHostWidgetHost.Seams) -> Void = { _ in }) -> ChromiumHostWidgetHost {
        _ = NSApplication.shared
        var seams = ChromiumHostWidgetHost.Seams()
        seams.makeView = { frame in
            let view = ChromiumHostPageView(frame: frame, inputTarget: .view, makeLayerHost: { _ in CALayer() })
            recorder.views.append(view)
            return view
        }
        seams.makePanel = { frame, takesKey in
            let panel = ChromiumHostWidgetPanel(frame: frame, takesKey: takesKey)
            recorder.panels.append(panel)
            return panel
        }
        seams.order = { window, parent, key in recorder.ordered.append((window, parent, key)) }
        seams.primaryScreenTop = { [primaryTop] in primaryTop }
        customize(&seams)
        return ChromiumHostWidgetHost(wire: wire, ownerWindow: { [owner] browser in browser == owner ? ownerWindow : nil },
                                      seams: seams)
    }

    func context(_ id: Int32, _ kind: ChromiumHostWidgetKind, contextID: UInt32 = 0x51,
                 bounds: CGRect = CGRect(x: 10, y: 20, width: 300, height: 200), title: String = "") -> ChromiumHostWidgetContext {
        ChromiumHostWidgetContext(widget: ChromiumHostWidgetID(rawValue: id), kind: kind, owner: owner, contextID: contextID,
                                  bounds: bounds, title: title)
    }

    func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 500), styleMask: .borderless,
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    // MARK: Wire

    @Test func widgetEventsDecodeFromTheShimEvent() {
        let a = Int64(ChromiumHostWidgetKind.devToolsWindow.rawValue) << 32 | 0x1234
        let event = CEFShimEvent(kind: 52, browser: 7, request: 3, a: a, b: 0, s1: "10,-20,300,200", s2: "DevTools")
        #expect(event == .widgetContext(ChromiumHostWidgetContext(
            widget: ChromiumHostWidgetID(rawValue: 3), kind: .devToolsWindow, owner: 7, contextID: 0x1234,
            bounds: CGRect(x: 10, y: -20, width: 300, height: 200), title: "DevTools")))
        #expect(event.browserID == 7)
        let gone = CEFShimEvent(kind: 53, browser: 7, request: 3, a: 0, b: 0, s1: "", s2: "")
        #expect(gone == .widgetGone(browser: 7, widget: ChromiumHostWidgetID(rawValue: 3)))
        #expect(gone.browserID == 7)
    }

    /// A field out of range changes nothing: no widget id, an unknown kind, bounds that are not
    /// four integers or have no area.
    @Test func aBadWidgetEventIsUnknown() {
        let devTools = Int64(ChromiumHostWidgetKind.devTools.rawValue) << 32
        let bad: [(Int32, Int64, String)] = [
            (0, devTools, "0,0,10,10"), (3, Int64(99) << 32, "0,0,10,10"), (3, devTools, "0,0,10"),
            (3, devTools, "0,0,10,10,1"), (3, devTools, "0,0,0,10"), (3, devTools, "0,0,10,-1"), (3, devTools, "a,0,10,10"),
            (3, devTools, ""),
        ]
        for (request, a, bounds) in bad {
            #expect(CEFShimEvent(kind: 52, browser: 7, request: request, a: a, b: 0, s1: bounds, s2: "") == .unknown(kind: 52))
        }
        #expect(CEFShimEvent(kind: 53, browser: 7, request: 0, a: 0, b: 0, s1: "", s2: "") == .unknown(kind: 53))
    }

    @Test func boundsFromTheTopLeftBecomeAnAppKitScreenRect() {
        let frame = context(1, .pagePopup).screenFrame(primaryTop: primaryTop)
        #expect(frame == CGRect(x: 10, y: 780, width: 300, height: 200))
    }

    @Test func eachKindHasItsPlacement() {
        #expect(ChromiumHostWidgetKind.extensionPopup.placement == .anchored(takesKey: true))
        #expect(ChromiumHostWidgetKind.pagePopup.placement == .anchored(takesKey: false))
        #expect(ChromiumHostWidgetKind.devToolsWindow.placement == .window)
        #expect(ChromiumHostWidgetKind.devTools.placement == .fill)
        #expect(ChromiumHostWidgetKind.popupWindow.placement == .fill)
        #expect(ChromiumHostWidgetKind.sidePanel.placement == .inPage)
        #expect(ChromiumHostWidgetKind.videoPictureInPicture.placement == .floating(keepsAspectRatio: true, takesKey: false))
        #expect(ChromiumHostWidgetKind.documentPictureInPicture.placement == .floating(keepsAspectRatio: false, takesKey: true))
        #expect(ChromiumHostWidgetKind.videoPictureInPicture.name == "video_pip")
        #expect(ChromiumHostWidgetKind.documentPictureInPicture.name == "document_pip")
    }

    // MARK: Picture-in-picture

    /// A video's picture-in-picture: its own floating panel at the bottom right of the screen, not a
    /// child of the opener's window, never key, with the video's shape; the host's next size keeps the
    /// panel's top left.
    @Test func videoPictureInPictureFloatsInItsOwnPanel() throws {
        let wire = RecordingWire()
        let recorder = Recorder()
        let ownerWindow = makeWindow()
        defer { ownerWindow.close() }
        var panels: [ChromiumHostPictureInPicturePanel] = []
        let host = makeHost(wire, recorder, ownerWindow: ownerWindow) { seams in
            seams.makePictureInPicturePanel = { size, _, keepsAspectRatio, takesKey in
                let panel = ChromiumHostPictureInPicturePanel(contentSize: size, on: nil, keepsAspectRatio: keepsAspectRatio,
                                                              takesKey: takesKey)
                panels.append(panel)
                return panel
            }
        }
        host.show(context(5, .videoPictureInPicture, bounds: CGRect(x: 0, y: 0, width: 320, height: 180)))
        let panel = try #require(panels.first)
        defer { panel.close() }
        #expect(recorder.panels.isEmpty, "not an anchored popup panel")
        #expect(recorder.ordered.count == 1 && recorder.ordered.first?.parent == nil && recorder.ordered.first?.key == false)
        #expect(!panel.canBecomeKey && !panel.canBecomeMain && !panel.hidesOnDeactivate)
        #expect(panel.level == .floating && panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(panel.contentAspectRatio == CGSize(width: 320, height: 180))
        let view = try #require(recorder.views.first)
        #expect(view.window === panel && view.frame.size == CGSize(width: 320, height: 180))
        #expect(host.diagnostics.map(\.kind) == [.videoPictureInPicture])

        // The host's new size (the next video's shape): same panel, its top left kept.
        panel.setFrameOrigin(CGPoint(x: 200, y: 300))
        let top = panel.frame.maxY
        host.show(context(5, .videoPictureInPicture, bounds: CGRect(x: 0, y: 0, width: 240, height: 240)))
        #expect(panels.count == 1)
        #expect(panel.contentRect(forFrameRect: panel.frame).size == CGSize(width: 240, height: 240))
        #expect(panel.frame.maxY == top && panel.frame.minX == 200)
        #expect(panel.contentAspectRatio == CGSize(width: 240, height: 240))

        host.remove(ChromiumHostWidgetID(rawValue: 5))
        #expect(view.window == nil && host.diagnostics.isEmpty)
    }

    /// A document picture-in-picture takes typing (its page's keys) and has no fixed shape.
    @Test func documentPictureInPictureTakesKeys() throws {
        var panels: [ChromiumHostPictureInPicturePanel] = []
        let host = makeHost(RecordingWire(), Recorder()) { seams in
            seams.makePictureInPicturePanel = { size, _, keepsAspectRatio, takesKey in
                let panel = ChromiumHostPictureInPicturePanel(contentSize: size, on: nil, keepsAspectRatio: keepsAspectRatio,
                                                              takesKey: takesKey)
                panels.append(panel)
                return panel
            }
        }
        host.show(context(6, .documentPictureInPicture, bounds: CGRect(x: 0, y: 0, width: 400, height: 300)))
        let panel = try #require(panels.first)
        defer { panel.close() }
        #expect(panel.canBecomeKey && !panel.canBecomeMain)
        #expect(panel.contentAspectRatio == .zero)
        host.hostEnded()
        #expect(!panel.isVisible && host.diagnostics.isEmpty)
    }

    /// The first place: the bottom right of the screen's visible frame, a margin in; a widget larger than
    /// the screen shrinks whole.
    @Test func pictureInPictureStartsAtTheBottomRight() {
        let visible = CGRect(x: 0, y: 40, width: 1_440, height: 860)
        let margin = ChromiumHostPictureInPicturePanel.margin
        #expect(ChromiumHostPictureInPicturePanel.initialFrame(contentSize: CGSize(width: 320, height: 180), visibleFrame: visible)
            == CGRect(x: 1_440 - margin - 320, y: 40 + margin, width: 320, height: 180))
        let big = ChromiumHostPictureInPicturePanel.initialFrame(contentSize: CGSize(width: 2_880, height: 1_620), visibleFrame: visible)
        #expect(big.width <= visible.width - 2 * margin && big.height <= visible.height - 2 * margin)
        #expect(abs(big.width / big.height - 16.0 / 9.0) < 0.01)
        #expect(ChromiumHostPictureInPicturePanel.initialFrame(contentSize: CGSize(width: 10, height: 10), visibleFrame: nil).size
            == CGSize(width: 10, height: 10))
    }

    // MARK: Anchored

    /// A date or datalist popup: a panel at its bounds, a child of its page's window, never key;
    /// the host placed it, so no geometry goes back; a move follows in the same panel.
    @Test func aPagePopupShowsInAPanelAtItsBounds() throws {
        let wire = RecordingWire()
        let recorder = Recorder()
        let ownerWindow = makeWindow()
        defer { ownerWindow.close() }
        let host = makeHost(wire, recorder, ownerWindow: ownerWindow)
        host.show(context(1, .pagePopup))
        let panel = try #require(recorder.panels.first)
        #expect(!panel.canBecomeKey && !panel.canBecomeMain)
        #expect(panel.level == .popUpMenu)
        #expect(panel.frame == CGRect(x: 10, y: 780, width: 300, height: 200))
        #expect(recorder.ordered.count == 1)
        #expect(recorder.ordered.first?.parent === ownerWindow)
        #expect(recorder.ordered.first?.key == false)
        let view = try #require(recorder.views.first)
        #expect(view.window === panel)
        #expect(view.contextID == 0x51)
        #expect(host.diagnostics.map(\.shown) == [true])

        host.show(context(1, .pagePopup))
        #expect(recorder.panels.count == 1 && recorder.ordered.count == 1)
        host.show(context(1, .pagePopup, contextID: 0x52, bounds: CGRect(x: 40, y: 20, width: 300, height: 260)))
        #expect(recorder.panels.count == 1)
        #expect(panel.frame == CGRect(x: 40, y: 720, width: 300, height: 260))
        #expect(view.contextID == 0x52)
        #expect(wire.geometries.isEmpty)

        host.remove(ChromiumHostWidgetID(rawValue: 1))
        #expect(view.window == nil && view.contextID == 0)
        #expect(host.diagnostics.isEmpty)
        #expect(wire.dismissed.isEmpty)
    }

    /// An extension popup takes the keys, and closes when it loses them, as Chrome's does.
    @Test func anExtensionPopupTakesKeyAndClosesWhenItLosesIt() throws {
        let wire = RecordingWire()
        let recorder = Recorder()
        let host = makeHost(wire, recorder)
        host.show(context(2, .extensionPopup))
        let panel = try #require(recorder.panels.first)
        #expect(panel.canBecomeKey && !panel.canBecomeMain)
        #expect(recorder.ordered.first?.key == true)
        panel.resignKey()
        #expect(wire.dismissed == [ChromiumHostWidgetID(rawValue: 2)])
        #expect(host.diagnostics.isEmpty)
        // The host's WIDGET_GONE after it changes nothing.
        host.remove(ChromiumHostWidgetID(rawValue: 2))
        #expect(wire.dismissed.count == 1)
    }

    /// A context already on its way when the person clicked away (the popup resizing to its
    /// content) does not bring the popup back or take the keys; after the host's WIDGET_GONE the
    /// id is a new widget's.
    @Test func aDismissedPopupStaysDownUntilItsGone() throws {
        let wire = RecordingWire()
        let recorder = Recorder()
        let host = makeHost(wire, recorder)
        host.show(context(2, .extensionPopup))
        try #require(recorder.panels.first).resignKey()
        host.show(context(2, .extensionPopup, bounds: CGRect(x: 10, y: 20, width: 320, height: 240)))
        #expect(host.diagnostics.isEmpty)
        #expect(recorder.panels.count == 1 && recorder.ordered.count == 1)
        host.remove(ChromiumHostWidgetID(rawValue: 2))
        host.show(context(2, .extensionPopup))
        #expect(host.diagnostics.map(\.widget) == [ChromiumHostWidgetID(rawValue: 2)])
        #expect(recorder.panels.count == 2)
        #expect(wire.dismissed == [ChromiumHostWidgetID(rawValue: 2)])
    }

    /// An undocked DevTools closed while a title change was on its way stays closed; its owner's
    /// close and the host's end forget what the person dismissed, as WIDGET_GONE does.
    @Test func aClosedDevToolsWindowIgnoresItsLateTitle() throws {
        let wire = RecordingWire()
        let recorder = Recorder()
        let host = makeHost(wire, recorder) { seams in
            seams.makeWindow = { frame, owner in
                let window = CEFDevToolsWindow(frame: frame, owner: owner)
                recorder.devToolsWindows.append(window)
                return window
            }
        }
        host.show(context(7, .devToolsWindow, title: "DevTools - example.com"))
        try #require(recorder.devToolsWindows.first).performClose(nil)
        host.show(context(7, .devToolsWindow, title: "DevTools - other.com"))
        #expect(recorder.devToolsWindows.count == 1)
        #expect(host.diagnostics.isEmpty)
        host.ownerClosed(owner)
        host.show(context(7, .devToolsWindow))
        #expect(recorder.devToolsWindows.count == 2)
        try #require(recorder.devToolsWindows.last).performClose(nil)
        host.hostEnded()
        host.show(context(7, .devToolsWindow))
        #expect(recorder.devToolsWindows.count == 3)
        host.hostEnded()
    }

    // MARK: Panes

    /// A docked DevTools fills the container cmux names, whenever its context and the container
    /// come, and its geometry goes to the host; a nil container takes it out.
    @Test func aDockedDevToolsFillsItsContainerAndReportsGeometry() throws {
        let wire = RecordingWire()
        let recorder = Recorder()
        let host = makeHost(wire, recorder)
        let window = makeWindow()
        defer { window.close() }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 250))
        window.contentView?.addSubview(container)

        host.show(context(3, .devTools))
        let view = try #require(recorder.views.first)
        #expect(view.superview == nil)
        #expect(host.diagnostics.map(\.shown) == [false])

        host.place(.devTools, owner: owner, in: container)
        #expect(view.superview === container)
        #expect(view.frame == container.bounds)
        #expect(wire.geometries.last?.0 == ChromiumHostWidgetID(rawValue: 3))
        #expect(wire.geometries.last?.1.width == 400 && wire.geometries.last?.1.height == 250)

        container.setFrameSize(NSSize(width: 300, height: 250))
        #expect(view.frame.size == NSSize(width: 300, height: 250))
        #expect(wire.geometries.last?.1.width == 300)

        host.place(.devTools, owner: owner, in: nil)
        #expect(view.superview == nil)
        host.place(.devTools, owner: owner, in: container)
        #expect(view.superview === container)
        // Another owner's container shows nothing of this one.
        host.place(.devTools, owner: owner + 1, in: NSView())
        #expect(view.superview === container)
    }

    /// The side panel's page sits at its bounds inside its tab's page (DIPs from the page's top
    /// left), over the page; the host placed it, so no geometry goes back.
    @Test func theSidePanelSitsAtItsBoundsInsideItsPage() throws {
        let wire = RecordingWire()
        let recorder = Recorder()
        let host = makeHost(wire, recorder)
        let page = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        let pageView = NSView(frame: page.bounds)
        page.addSubview(pageView)
        host.place(.sidePanel, owner: owner, in: page)
        host.show(context(4, .sidePanel, bounds: CGRect(x: 400, y: 40, width: 200, height: 460)))
        let view = try #require(recorder.views.first)
        #expect(view.superview === page)
        #expect(page.subviews.last === view)
        #expect(view.frame == CGRect(x: 400, y: 0, width: 200, height: 460))
        #expect(wire.geometries.isEmpty)
        // The panel closed: the controller takes the container away.
        host.place(.sidePanel, owner: owner, in: nil)
        #expect(view.superview == nil)
    }

    /// Two widgets for one container (a popup window's tab replaced): the newest shows, and the
    /// older one shows again when the newest goes. A change of the older one does not take the
    /// container back.
    @Test func theNewestWidgetOfAContainerShows() throws {
        let wire = RecordingWire()
        let recorder = Recorder()
        let host = makeHost(wire, recorder)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        host.place(.popupWindow, owner: owner, in: container)
        host.show(context(5, .popupWindow))
        host.show(context(6, .popupWindow))
        let first = try #require(recorder.views.first)
        let second = try #require(recorder.views.last)
        #expect(first.superview == nil)
        #expect(second.superview === container)
        host.show(context(5, .popupWindow, contextID: 0x99))
        #expect(first.superview == nil && second.superview === container)
        host.place(.popupWindow, owner: owner, in: container)
        #expect(first.superview == nil && second.superview === container)
        host.remove(ChromiumHostWidgetID(rawValue: 6))
        #expect(first.superview === container)
        #expect(first.contextID == 0x99)
    }

    // MARK: Window

    /// An undocked DevTools: a titled window with the widget's title; the close button takes it
    /// down at once and tells the host.
    @Test func anUndockedDevToolsShowsInAWindowThatTheCloseButtonCloses() throws {
        let wire = RecordingWire()
        let recorder = Recorder()
        let host = makeHost(wire, recorder) { seams in
            seams.makeWindow = { frame, owner in
                let window = CEFDevToolsWindow(frame: frame, owner: owner)
                recorder.devToolsWindows.append(window)
                return window
            }
        }

        host.show(context(7, .devToolsWindow, title: "DevTools - example.com"))
        let window = try #require(recorder.devToolsWindows.first)
        let view = try #require(recorder.views.first)
        #expect(window.title == "DevTools - example.com")
        #expect(view.window === window)
        #expect(recorder.ordered.first?.key == true)
        #expect(window.delegate is ChromiumHostWidgetWindowDelegate)
        host.show(context(7, .devToolsWindow, title: "DevTools - other.com"))
        #expect(recorder.devToolsWindows.count == 1 && window.title == "DevTools - other.com")
        // The window's own frame goes to the host as the person moves and resizes it.
        #expect(wire.geometries.last?.0 == ChromiumHostWidgetID(rawValue: 7))

        window.performClose(nil)
        #expect(wire.dismissed == [ChromiumHostWidgetID(rawValue: 7)])
        #expect(view.window == nil && window.delegate == nil)
        #expect(host.diagnostics.isEmpty)
    }

    // MARK: Lifetime

    @Test func anOwnersCloseAndTheHostsEndTakeTheirWidgetsDown() {
        let wire = RecordingWire()
        let recorder = Recorder()
        let host = makeHost(wire, recorder)
        host.show(context(1, .pagePopup))
        host.show(context(2, .devTools))
        var other = context(3, .extensionPopup)
        other.owner = owner + 1
        host.show(other)
        host.ownerClosed(owner)
        #expect(host.diagnostics.map(\.widget) == [ChromiumHostWidgetID(rawValue: 3)])
        #expect(recorder.views.prefix(2).allSatisfy { $0.window == nil && $0.contextID == 0 })
        host.hostEnded()
        #expect(host.diagnostics.isEmpty)
        #expect(wire.dismissed.isEmpty)
    }

    /// A widget id the host reuses for another kind shows the new widget, not the old one moved.
    @Test func aReusedIdForAnotherKindReplacesTheWidget() {
        let wire = RecordingWire()
        let recorder = Recorder()
        let host = makeHost(wire, recorder)
        host.show(context(1, .pagePopup))
        host.show(context(1, .extensionPopup))
        #expect(recorder.views.count == 2)
        #expect(recorder.views.first?.window == nil)
        #expect(host.diagnostics.map(\.kind) == [.extensionPopup])
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// Input reaches the widget as a page's does: focus here.
    @Test func aWidgetsInputGoesToTheHost() throws {
        let wire = RecordingWire()
        let recorder = Recorder()
        let host = makeHost(wire, recorder)
        host.show(context(8, .extensionPopup))
        let panel = try #require(recorder.panels.first)
        let view = try #require(recorder.views.first)
        #expect(panel.makeFirstResponder(view))
        #expect(wire.inputs.map(\.0) == [ChromiumHostWidgetID(rawValue: 8)])
        #expect(wire.inputs.first?.1.kind == .focus)
        host.remove(ChromiumHostWidgetID(rawValue: 8))
    }
    #endif
}
