import AppKit
import CmuxNextCompat
import Foundation

/// The shim's color chooser, device chooser and screen-share picker calls (fork API 31, tasks 227 and
/// 228). In host mode the setters are the remote shim's local exports: it keeps the C function and
/// calls it from the host's pushes, on the main thread; the answers are one control op each.
nonisolated struct CEFShimChooserOps {
    /// The fork API whose handlers send these requests as data (task 227).
    static let forkAPI: Int32 = 31

    /// fn(context, event, browser, token, color, data): `CMUX_SHIM_COLOR_CHOOSER_*`, data the fork's
    /// `cmux_color_chooser_t` on OPEN.
    typealias ColorFn = @convention(c) (UnsafeMutableRawPointer?, Int32, Int32, Int64, UInt32, UnsafeRawPointer?) -> Void
    /// fn(context, event, browser, token, data): `CMUX_SHIM_DEVICE_CHOOSER_*` or `CMUX_SHIM_DESKTOP_MEDIA_*`.
    typealias ChooserFn = @convention(c) (UnsafeMutableRawPointer?, Int32, Int32, Int64, UnsafeRawPointer?) -> Void

    let setColorHandler: @convention(c) (ColorFn?, UnsafeMutableRawPointer?) -> Int32
    let setDeviceHandler: @convention(c) (ChooserFn?, UnsafeMutableRawPointer?) -> Int32
    let setDesktopMediaHandler: @convention(c) (ChooserFn?, UnsafeMutableRawPointer?) -> Int32
    /// token, color (0xAARRGGBB).
    let colorChoose: @convention(c) (Int64, UInt32) -> Int32
    let colorEnd: @convention(c) (Int64) -> Int32
    /// token, action (`CMUX_DEVICE_CHOOSER_*`), the chosen rows as int64 records, their count.
    let deviceAnswer: @convention(c) (Int64, Int32, UnsafePointer<Int64>?, Int32) -> Int32
    /// token, source type (one `CMUX_DESKTOP_MEDIA_*` bit, 0 cancels), display or window id, tab browser, audio.
    let desktopMediaAnswer: @convention(c) (Int64, Int32, Int64, Int32, Int32) -> Int32

    init(_ r: CEFShimLibrary.Resolver) throws(CEFShimLibrary.LoadError) {
        setColorHandler = try r("cmux_shim_set_color_chooser_handler")
        setDeviceHandler = try r("cmux_shim_set_device_chooser_handler")
        setDesktopMediaHandler = try r("cmux_shim_set_desktop_media_handler")
        colorChoose = try r("cmux_shim_color_chooser_choose")
        colorEnd = try r("cmux_shim_color_chooser_end")
        deviceAnswer = try r("cmux_shim_device_chooser_answer")
        desktopMediaAnswer = try r("cmux_shim_desktop_media_answer")
    }
}

/// ``ChromiumHostChooserWire`` on the runtime's shim: in host mode each answer is one post the host's
/// shim makes into the fork's call (`cmux_color_chooser_choose` and the rest). The results only say
/// whether Chromium still had the request open, which an answer never depends on.
final class CEFShimChooserWire: ChromiumHostChooserWire {
    private let ops: CEFShimChooserOps

    init(ops: CEFShimChooserOps) {
        self.ops = ops
    }

    func chooseColor(token: Int64, color: UInt32) { _ = ops.colorChoose(token, color) }
    func endColor(token: Int64) { _ = ops.colorEnd(token) }

    func answerDevice(token: Int64, _ answer: ChromiumHostDeviceAnswer) {
        // `cmux_shim_device_choice` is one int64.
        let rows = answer.rows.map(Int64.init)
        _ = unsafe rows.withUnsafeBufferPointer { unsafe ops.deviceAnswer(token, answer.action.rawValue, $0.baseAddress, Int32(clamping: $0.count)) }
    }

    func answerDesktopMedia(token: Int64, _ answer: ChromiumHostDesktopMediaAnswer) {
        _ = ops.desktopMediaAnswer(token, answer.sourceType.rawValue, answer.nativeID, answer.tabBrowser, answer.audio ? 1 : 0)
    }
}

/// The seam adapter of the shim's chooser handlers: their C entries (main thread: the remote shim calls them from
/// the host's pushes). Each reads the fork's struct into a value during the call, then hands it to the runtime its
/// context names, on the main actor.
nonisolated enum CEFChooserCallbacks {
    static let color: CEFShimChooserOps.ColorFn = { context, event, browser, token, color, data in
        // SAFETY: only the addresses are read; CEFRuntime.from resolves the context, the fork struct is read now.
        let (address, dataAddress) = unsafe (UInt(bitPattern: context), UInt(bitPattern: data))
        let request = ChromiumHostColorChooserRequest(forkAddress: dataAddress)
        guard address != 0 else { return }
        deliver { CEFRuntime.from(address)?.hostStart?.choosers?.colorEvent(event, browser: browser, token: token, color: color, request: request) }
    }

    static let device: CEFShimChooserOps.ChooserFn = { context, event, browser, token, data in
        // SAFETY: as in `color`.
        let (address, dataAddress) = unsafe (UInt(bitPattern: context), UInt(bitPattern: data))
        let state = ChromiumHostDeviceChooserState(forkAddress: dataAddress)
        guard address != 0 else { return }
        deliver { CEFRuntime.from(address)?.hostStart?.choosers?.deviceEvent(event, browser: browser, token: token, state: state) }
    }

    static let desktopMedia: CEFShimChooserOps.ChooserFn = { context, event, browser, token, data in
        // SAFETY: as in `color`.
        let (address, dataAddress) = unsafe (UInt(bitPattern: context), UInt(bitPattern: data))
        let request = ChromiumHostDesktopMediaRequest(forkAddress: dataAddress)
        guard address != 0 else { return }
        deliver { CEFRuntime.from(address)?.hostStart?.choosers?.desktopMediaEvent(event, browser: browser, token: token, request: request) }
    }

    /// Runs an event on the main actor: now on the main thread, else in order with every other run-loop block,
    /// as cefEventCallback does (the struct is already a value).
    private static func deliver(_ event: @escaping @MainActor () -> Void) {
        guard Thread.isMainThread else { return MainRunLoopBlock.perform(event) }
        MainActor.assumeIsolated { event() } // main-proof: guarded by Thread.isMainThread above
    }
}

extension CEFRuntime {
    /// Host mode with feature `chromiumHostChoosers` on a fork whose handlers send the requests as data:
    /// the color chooser, device choosers and screen-share picker show in cmux. Otherwise Chromium shows
    /// its own, which in host mode would open in the host.
    var drawsChoosersInCmux: Bool {
        hostStart?.drawsChoosers == true && forkAPIVersion >= CEFShimChooserOps.forkAPI
    }

    /// Host mode, before `cmux_shim_initialize`: cmux's handlers, so the host installs its own once it
    /// started Chromium, and every later host again (the remote shim sends them at each attach).
    /// `context` is the runtime's callback token.
    func showHostChoosers(_ shim: CEFShimLibrary, context: UnsafeMutableRawPointer) {
        guard let hostStart, drawsChoosersInCmux else { return }
        // One for the runtime: a restarted host initializes again with the same handlers.
        hostStart.choosers = hostStart.choosers ?? ChromiumHostChoosers(wire: CEFShimChooserWire(ops: shim.choosers), seams: chooserSeams())
        // SAFETY: C functions of the header's handler types; `context` is the runtime's token, which
        // CEFRuntime.from resolves (or ignores once the runtime is gone).
        _ = unsafe shim.choosers.setColorHandler(CEFChooserCallbacks.color, context)
        _ = unsafe shim.choosers.setDeviceHandler(CEFChooserCallbacks.device, context)
        _ = unsafe shim.choosers.setDesktopMediaHandler(CEFChooserCallbacks.desktopMedia, context)
    }

    /// Where the choosers show: over the page view of the tab that asked, which a tab dialog blocks
    /// alone, as Chrome anchors its chooser bubbles to the tab's contents.
    private func chooserSeams() -> ChromiumHostChoosers.Seams {
        var seams = ChromiumHostChoosers.Seams()
        seams.pageView = { [weak self] browser in self?.popupMenuView(of: browser) }
        seams.tabs = { [weak self] in
            guard let self else { return [] }
            return tabsByBrowser.compactMap { browser, tab in
                tab.isClosed ? nil : ChromiumHostShareTab(browser: browser, title: tab.state.title ?? tab.state.url?.absoluteString ?? "")
            }.sorted { $0.browser < $1.browser }
        }
        return seams
    }
}

extension CEFEngine {
    /// The host's choosers cmux shows now (`debug.cef` `host_choosers`); nil when cmux shows none
    /// (in process, the feature off, or a fork below API 31).
    public var hostChoosers: CEFHostChooserReport? { CEFRuntime.shared.hostStart?.choosers?.report }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// Picks `color` (0xRRGGBB) in the open color chooser, as the panel would (chromium-host-bench.py's
    /// color row). False when none is open.
    public func pickHostColor(_ color: UInt32) -> Bool {
        CEFRuntime.shared.hostStart?.choosers?.pickColor(0xFF00_0000 | color) ?? false
    }

    /// Closes the open color chooser, as closing the panel would. False when none is open.
    public func closeHostColorChooser() -> Bool {
        CEFRuntime.shared.hostStart?.choosers?.closeColor() ?? false
    }
    #endif
}
