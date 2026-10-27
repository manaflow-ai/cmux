import AppKit
import CmuxNextSharedRegionC
import Darwin
import Foundation
import PDFKit

/// File > Print… of a page in host mode (task p01-process-065, feature `chromiumHostPrint`): the
/// Chromium Host prints the page to PDF (`kOpPrintToPdf`, ChromiumHost/src/host_print.h:
/// `CefBrowserHost::PrintToPDF`) and hands the document back in a sealed shared memory region with
/// its REPLY; cmux shows the system print panel on that PDF as a sheet on the page's window
/// (``BrowserPagePrint/printPDF(_:on:done:)``), so Chromium's print preview never opens in the
/// host. Chrome moves a printed document the same way: the renderer's PDF reaches the browser
/// process as a read-only shared memory region (components/printing/common/print.mojom,
/// `DidPrintContentParams`), and the platform print dialog runs in the process that owns the window.
///
/// A page's own `window.print()` takes the same path: the host stops it before Chromium's preview
/// opens and sends PAGE_PRINT (``pageAsked(_:browser:on:runtime:)``); the page's `window.print()`
/// returns when cmux ends the request, once the panel ended, as Chrome's returns when its preview
/// closes (chrome/browser/printing/print_view_manager.cc, `SetupScriptedPrintPreview`).
final class ChromiumHostPagePrints {
    /// The remote dylib's print calls (ChromiumHost/client/remote_shim_runtime.h).
    struct Calls {
        typealias PrintFn = @convention(c) (Int32, Double, Double) -> Int32
        typealias TakeRegionFn = @convention(c) () -> Int32
        typealias SetPagePrintsFn = @convention(c) (Int32) -> Int32
        typealias EndPagePrintFn = @convention(c) (Int64) -> Int32

        /// `cmux_remote_shim_print_to_pdf(browser, paper width, paper height)`, inches; 1 when sent.
        let print: PrintFn
        /// `cmux_remote_shim_take_reply_region()`: the region of the REPLY being delivered, -1 when none.
        let takeRegion: TakeRegionFn
        /// `cmux_remote_shim_set_page_prints(enabled)`: 1 sends the prints pages start to cmux (PAGE_PRINT).
        let setPagePrints: SetPagePrintsFn
        /// `cmux_remote_shim_page_print_end(request)`: the page's `window.print()` returns; 1 when sent.
        let endPagePrint: EndPagePrintFn

        /// Nil when the remote dylib lacks one of them.
        init?(_ remote: CEFRemoteShim) {
            guard let print = remote.symbol("cmux_remote_shim_print_to_pdf"),
                  let take = remote.symbol("cmux_remote_shim_take_reply_region"),
                  let setPagePrints = remote.symbol("cmux_remote_shim_set_page_prints"),
                  let endPagePrint = remote.symbol("cmux_remote_shim_page_print_end") else { return nil }
            // SAFETY: the symbols are the C functions of remote_shim_runtime.h with these signatures, in a
            // dylib that is never closed.
            self.print = unsafe unsafeBitCast(print, to: PrintFn.self)
            takeRegion = unsafe unsafeBitCast(take, to: TakeRegionFn.self)
            self.setPagePrints = unsafe unsafeBitCast(setPagePrints, to: SetPagePrintsFn.self)
            self.endPagePrint = unsafe unsafeBitCast(endPagePrint, to: EndPagePrintFn.self)
        }
    }

    /// Shows the print panel on a PDF as a sheet on a window; `done` when it ends. False when it cannot
    /// show (``BrowserPagePrint/printPDF(_:on:done:)`` in the app).
    typealias ShowPanel = (_ document: PDFDocument, _ window: NSWindow, _ done: @escaping @MainActor () -> Void) -> Bool

    /// How long the host may take to print a page: PrintToPDF lays out and paints every page.
    static let replyTimeout: Duration = .seconds(60)

    /// Prints asked for, PDFs that came, print panels shown, and prints that showed no panel.
    private(set) var asked = 0
    private(set) var printed = 0
    private(set) var shown = 0
    private(set) var failed = 0
    /// Prints pages started (PAGE_PRINT), and those ended (their `window.print()` returned).
    private(set) var pageAsked = 0
    private(set) var pageEnded = 0
    /// The attached host sends the prints pages start (its fork has the page-print hook, task p01-process-242);
    /// without it a page's own window.print() opens Chromium's preview in the host.
    private(set) var pageHook = false
    /// The window whose print panel shows now, until the panel ends.
    private(set) weak var panelWindow: NSWindow?
    /// The remote dylib's calls, bound at the first print (one dylib for every host).
    private var calls: Calls?
    private let showPanel: ShowPanel

    init(calls: Calls? = nil, showPanel: @escaping ShowPanel = { BrowserPagePrint.printPDF($0, on: $1, done: $2) }) {
        self.calls = calls
        self.showPanel = showPanel
    }

    /// The attached host sends the prints pages start to cmux (PAGE_PRINT) from now on, and every later
    /// host of the session too (`CEFHostStart.attached()`, once per attach, after the host's HELLO, which
    /// says whether it has the hook).
    func hostAttached(_ remote: CEFRemoteShim) {
        if calls == nil { calls = Calls(remote) }
        pageHook = calls?.setPagePrints(1) == 1
    }

    /// Asks the attached host for `browser`'s page as a PDF on the print panel's paper; the panel shows
    /// on `window` once the PDF comes. False when nothing was sent (no host attached, a host that does not
    /// print, or `window` already shows a sheet), as for a page that cannot print. After true, `ended`
    /// runs once: when the panel ends, or when no panel shows.
    func print(_ browser: Int32, on window: NSWindow, runtime: CEFRuntime, ended: (@MainActor () -> Void)? = nil) -> Bool {
        guard window.attachedSheet == nil, let hostStart = runtime.hostStart, let calls = boundCalls(hostStart) else { return false }
        let paper = NSPrintInfo.shared.paperSize
        guard calls.print(browser, Double(paper.width) / 72, Double(paper.height) / 72) == 1, let token = hostStart.expectReply() else { return false }
        asked += 1
        runtime.whenSettled(CEFShimAnswer<ChromiumHostPrintedPDF>.later(token), label: "print to PDF",
                            timeout: Self.replyTimeout) { [weak self, weak window] result in
            // In the REPLY's turn: the region is taken now, or the remote shim closes it when this returns.
            let region = calls.takeRegion()
            guard let self else {
                if region >= 0 { Darwin.close(region) }
                ended?()
                return
            }
            self.show(result, region: region, on: window, ended: ended)
        }
        return true
    }

    /// A print page `browser` started (PAGE_PRINT `request`), printed as File > Print… is on `window`, its
    /// tab's. The request ends, and the page's `window.print()` returns, when the panel ends, or at once
    /// when none can show (no window, a window that shows a sheet, a host that cannot print).
    func pageAsked(_ request: Int64, browser: Int32, on window: NSWindow?, runtime: CEFRuntime) {
        pageAsked += 1
        let hostStart = runtime.hostStart
        let calls = hostStart.flatMap { boundCalls($0) }
        // The host the request came from: one attached later hands out the same ids again.
        let from = hostStart?.hostEnds
        let end: @MainActor () -> Void = { [weak self, weak hostStart] in
            self?.pageEnded += 1
            // Not sent when the host it came from is gone: the request went with it.
            guard let hostStart, hostStart.hostEnds == from else { return }
            _ = calls?.endPagePrint(request)
        }
        guard let window, self.print(browser, on: window, runtime: runtime, ended: end) else { return end() }
    }

    /// Ends the print panel showing now, as its Cancel would (`debug.cef` `print_cancel`). False when none shows.
    func cancelPanel() -> Bool {
        guard let window = panelWindow, let sheet = window.attachedSheet else { return false }
        window.endSheet(sheet, returnCode: .cancel)
        return true
    }

    var report: CEFHostPagePrintReport {
        CEFHostPagePrintReport(asked: asked, printed: printed, shown: shown, failed: failed, showing: panelWindow?.attachedSheet != nil,
                               pageAsked: pageAsked, pageEnded: pageEnded, pageHook: pageHook)
    }

    private func boundCalls(_ hostStart: CEFHostStart) -> Calls? {
        if let calls { return calls }
        guard let remote = hostStart.remote else { return nil }
        calls = Calls(remote)
        return calls
    }

    private func show(_ result: Result<ChromiumHostPrintedPDF, CEFHostReplyError>, region: Int32, on window: NSWindow?,
                      ended: (@MainActor () -> Void)?) {
        var data: Data?
        if region >= 0 {
            if case .success(let reply) = result, reply.printed { data = Self.mappedPDF(region, count: reply.size) }
            // The mapping stays valid once the descriptor is closed.
            Darwin.close(region)
        }
        guard let data, let document = PDFDocument(data: data) else {
            failed += 1
            ended?()
            return
        }
        printed += 1
        let panelEnded: @MainActor () -> Void = { [weak self] in
            self?.panelWindow = nil
            ended?()
        }
        // The window may have closed, or shown another sheet, while the host printed.
        guard let window, showPanel(document, window, panelEnded) else {
            failed += 1
            ended?()
            return
        }
        shown += 1
        panelWindow = window
    }

    /// The first `count` bytes of the sealed region `fd` as data over a read-only mapping, unmapped
    /// when the data goes (no copy of the PDF); nil when `fd` is not a sealed region of that many bytes.
    /// Does not close `fd`.
    nonisolated static func mappedPDF(_ fd: Int32, count: Int) -> Data? {
        guard count > 0, count <= ChromiumHostPrintedPDF.maxBytes, cmux_shared_region_is_sealed(fd) != 0 else { return nil }
        var info = stat()
        // SAFETY: fstat writes one `stat` into `info` during the call.
        guard unsafe fstat(fd, &info) == 0, info.st_size >= off_t(count) else { return nil }
        // SAFETY: a read-only mapping of `count` bytes, which the sealed region holds (st_size above) and
        // cannot shrink; the data owns it and unmaps it once, with the same size, when it goes.
        guard let mapping = unsafe mmap(nil, count, PROT_READ, MAP_SHARED, fd, 0),
              unsafe mapping != UnsafeMutableRawPointer(bitPattern: -1) else { return nil }
        return unsafe Data(bytesNoCopy: mapping, count: count, deallocator: .custom { pointer, size in
            // SAFETY: the mapping made above, unmapped once by the data's deallocator.
            _ = unsafe munmap(pointer, size)
        })
    }
}

/// A `kOpPrintToPdf` REPLY: whether the page printed and the PDF's size in bytes (its region came
/// with the frame; ChromiumHost/src/host_print.h).
nonisolated struct ChromiumHostPrintedPDF: CEFHostReplyValue, Equatable {
    /// The most bytes a region carries: the control channel's `kMaxSharedBytes`.
    static let maxBytes = 128 * 1024 * 1024

    let printed: Bool
    let size: Int

    init(printed: Bool, size: Int) {
        self.printed = printed
        self.size = size
    }

    init(reply fields: inout CEFHostReplyFields) throws(CEFHostReplyError) {
        let result = try fields.int32()
        let size = try fields.int64()
        guard result == 0 || result == 1, size >= 0, size <= Int64(Self.maxBytes), (result == 1) == (size > 0) else {
            throw .malformed
        }
        printed = result == 1
        self.size = Int(size)
    }
}

/// `debug.cef` `host_print`: the pages cmux printed through the host.
public struct CEFHostPagePrintReport: Equatable, Sendable {
    public let asked: Int
    public let printed: Int
    public let shown: Int
    public let failed: Int
    /// A print panel shows now.
    public let showing: Bool
    /// Prints pages started with `window.print()` (PAGE_PRINT), and those ended: their `window.print()` returned.
    public let pageAsked: Int
    public let pageEnded: Int
    /// The attached host sends the prints pages start: its fork has the page-print hook (task p01-process-242).
    public let pageHook: Bool

    init(asked: Int, printed: Int, shown: Int, failed: Int, showing: Bool, pageAsked: Int = 0, pageEnded: Int = 0,
         pageHook: Bool = false) {
        self.asked = asked
        self.printed = printed
        self.shown = shown
        self.failed = failed
        self.showing = showing
        self.pageAsked = pageAsked
        self.pageEnded = pageEnded
        self.pageHook = pageHook
    }
}

extension CEFRuntime {
    /// A page's own `window.print()` in host mode (PAGE_PRINT): printed through cmux's panel on its tab's window.
    func pagePrintAsked(_ request: Int64, browser: Int32) {
        hostStart?.pagePrints?.pageAsked(request, browser: browser, on: tabsByBrowser[browser]?.contentView.window, runtime: self)
    }
}

extension CEFEngine {
    /// The host's page prints so far; nil when cmux does not print through the host (in process, or
    /// feature `chromiumHostPrint` off).
    public var hostPagePrints: CEFHostPagePrintReport? {
        CEFRuntime.shared.hostStart?.pagePrints?.report
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// Ends the print panel of a host page print, as its Cancel would. False when none shows.
    public func cancelHostPrintPanel() -> Bool {
        CEFRuntime.shared.hostStart?.pagePrints?.cancelPanel() ?? false
    }
    #endif
}
