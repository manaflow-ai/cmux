import AppKit
@testable import CmuxNextBrowser
import Testing

/// How host mode turns the hosted widgets on and off: the source's feature choice
/// reaches the runtime's host start, the start builds the widget host only when the host's shim
/// has every widget op, the shim's ops carry geometry, dismiss and input, and the host's end takes
/// every widget down.
@MainActor @Suite(.serialized) struct ChromiumHostWidgetWiringTests {
    private static func scratch() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "cef-widgets-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private static func idleRuntime() -> CEFRuntime {
        CEFRuntime(storage: CEFProfileStorage(root: scratch()))
    }

    @Test func theSourcesChoiceReachesTheHostStart() {
        #expect(!CEFRuntimeSource(layout: nil).showsHostWidgets)
        let on = Self.idleRuntime()
        on.adopt(stores: .inMemory(), signInCallbacks: CEFSignInCallbacks(), hostSupervisor: EndingSupervisor(), hostWidgets: true)
        #expect(on.hostStart?.showsWidgets == true)
        let off = Self.idleRuntime()
        off.adopt(stores: .inMemory(), signInCallbacks: CEFSignInCallbacks(), hostSupervisor: EndingSupervisor())
        #expect(off.hostStart?.showsWidgets == false)
    }

    /// The feature on and a host shim with the widget ops: the start builds the widget host.
    @Test func theFeatureShowsTheHostsWidgetsAtTheStart() throws {
        let runtime = Self.idleRuntime()
        runtime.hostStart = CEFHostStart(supervisor: EndingSupervisor(), showsWidgets: true)
        runtime.showHostWidgets(try CEFShimLibrary.resolving(WidgetSpy.symbol))
        #expect(runtime.widgetHost != nil)
    }

    /// Off, in process, or with a host whose hello lists no widget op: no widget host, so every
    /// widget event and placement does nothing.
    @Test func noWidgetHostWithoutTheFeatureOrTheOps() throws {
        let off = Self.idleRuntime()
        off.hostStart = CEFHostStart(supervisor: EndingSupervisor())
        off.showHostWidgets(try CEFShimLibrary.resolving(WidgetSpy.symbol))
        #expect(off.widgetHost == nil)

        let inProcess = Self.idleRuntime()
        inProcess.showHostWidgets(try CEFShimLibrary.resolving(WidgetSpy.symbol))
        #expect(inProcess.widgetHost == nil)

        let oldHost = Self.idleRuntime()
        oldHost.hostStart = CEFHostStart(supervisor: EndingSupervisor(), showsWidgets: true)
        let shim = try CEFShimLibrary.resolving(WidgetSpy.symbol, hostExports: [])
        #expect(!shim.widgets.isComplete)
        oldHost.showHostWidgets(shim)
        #expect(oldHost.widgetHost == nil)
    }

    /// A host that ends sends no WIDGET_GONE: the supervisor's end takes its panels and windows down.
    @Test func theHostsEndTakesItsWidgetsDown() {
        _ = NSApplication.shared
        let supervisor = EndingSupervisor()
        let start = CEFHostStart(supervisor: supervisor, showsWidgets: true)
        var seams = ChromiumHostWidgetHost.Seams()
        seams.makeView = { ChromiumHostPageView(frame: $0, inputTarget: .view, makeLayerHost: { _ in CALayer() }) }
        seams.order = { _, _, _ in }
        seams.primaryScreenTop = { 1_000 }
        let host = ChromiumHostWidgetHost(wire: CEFShimWidgetWire(ops: CEFShimWidgetOps(setGeometry: nil, dismiss: nil, sendInput: nil)),
                                          ownerWindow: { _ in nil }, seams: seams)
        start.widgetHost = host
        let bounds = CGRect(x: 10, y: 20, width: 300, height: 200)
        host.show(ChromiumHostWidgetContext(widget: ChromiumHostWidgetID(rawValue: 1), kind: .pagePopup, owner: 7, contextID: 0x51, bounds: bounds))
        host.show(ChromiumHostWidgetContext(widget: ChromiumHostWidgetID(rawValue: 2), kind: .devToolsWindow, owner: 7, contextID: 0x52,
                                            bounds: bounds, title: "DevTools"))
        #expect(host.diagnostics.count == 2)
        supervisor.end()
        #expect(host.diagnostics.isEmpty)
    }

    /// Each wire call is one shim op with the widget's id and the values as the op lists them.
    @Test func theShimWireSendsEachOp() throws {
        WidgetSpy.reset()
        let wire = CEFShimWidgetWire(ops: try CEFShimLibrary.resolving(WidgetSpy.symbol).widgets)
        let widget = ChromiumHostWidgetID(rawValue: 9)
        wire.widget(widget, movedTo: ChromiumHostGeometry(screenRect: CGRect(x: 100, y: 50, width: 640, height: 480), scale: 2))
        #expect(WidgetSpy.geometry == [9, 100, 50, 640, 480, 2_000])
        wire.dismiss(widget)
        #expect(WidgetSpy.dismissed == [9])
        #if DEBUG || CMUX_BENCH_HOOKS
        var frame = ChromiumHostFrame(.key, v: [0, 36, 1], flags: 0x10_0000, t0: 123)
        frame.ch = 13
        frame.unmod = 13
        wire.widget(widget, input: frame)
        #expect(WidgetSpy.input == [9, Int64(ChromiumHostFrame.Kind.key.rawValue), 0, 36, 1, 0, 0, 0, 0x10_0000, 123, 13, 13])
        #endif
    }

    /// The side panel's container lets clicks through to the page except on its widget.
    @Test func theSidePanelContainerTakesOnlyItsWidgetsClicks() {
        let container = SidePanelWidgetContainer(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        let widget = NSView(frame: NSRect(x: 400, y: 0, width: 200, height: 460))
        container.addSubview(widget)
        #expect(container.hitTest(NSPoint(x: 100, y: 100)) == nil)
        #expect(container.hitTest(NSPoint(x: 450, y: 100)) === widget)
    }
}

/// A supervisor that is never asked for a wire; ``end()`` reports the host's end as a real one would.
@MainActor
private final class EndingSupervisor: ChromiumHostSupervising {
    private var ended: [@MainActor () -> Void] = []

    func attachment() async throws(ChromiumHostAttachError) -> ChromiumHostAttachment {
        throw .cannotStart("not used in ChromiumHostWidgetWiringTests")
    }

    func observeHostEnds(_ ended: @escaping @MainActor () -> Void) {
        self.ended.append(ended)
    }

    func end() {
        for handler in ended { handler() }
    }
}

/// The shim with the widget ops recording their arguments; every other function does nothing and returns 0.
private nonisolated enum WidgetSpy {
    nonisolated(unsafe) static var geometry: [Int32] = []
    nonisolated(unsafe) static var dismissed: [Int32] = []
    nonisolated(unsafe) static var input: [Int64] = []

    static func reset() {
        geometry = []
        dismissed = []
        input = []
    }

    static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        let setGeometry: @convention(c) (Int32, Int32, Int32, Int32, Int32, Int32) -> Void = { widget, x, y, width, height, scale in
            WidgetSpy.geometry = [widget, x, y, width, height, scale]
        }
        let dismiss: @convention(c) (Int32) -> Void = { widget in WidgetSpy.dismissed.append(widget) }
        let sendInput: @convention(c) (Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int64, Int64, Int32, Int32) -> Void = {
            widget, kind, v0, v1, v2, v3, v4, v5, flags, time, ch, unmod in
            WidgetSpy.input = [Int64(widget), Int64(kind), Int64(v0), Int64(v1), Int64(v2), Int64(v3), Int64(v4), Int64(v5),
                               flags, time, Int64(ch), Int64(unmod)]
        }
        let nothing: @convention(c) () -> Int = { 0 }
        return switch name {
        case "cmux_shim_widget_set_geometry": unsafeBitCast(setGeometry, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_widget_dismiss": unsafeBitCast(dismiss, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_widget_send_input": unsafeBitCast(sendInput, to: UnsafeMutableRawPointer.self)
        default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
        }
    }
}
