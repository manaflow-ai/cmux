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
final class ChromiumHostPagePrints {
    /// The remote dylib's print calls (ChromiumHost/client/remote_shim_runtime.h).
    struct Calls {
        typealias PrintFn = @convention(c) (Int32, Double, Double) -> Int32
        typealias TakeRegionFn = @convention(c) () -> Int32

        /// `cmux_remote_shim_print_to_pdf(browser, paper width, paper height)`, inches; 1 when sent.
        let print: PrintFn
        /// `cmux_remote_shim_take_reply_region()`: the region of the REPLY being delivered, -1 when none.
        let takeRegion: TakeRegionFn

        /// Nil when the remote dylib has neither.
        init?(_ remote: CEFRemoteShim) {
            guard let print = remote.symbol("cmux_remote_shim_print_to_pdf"),
                  let take = remote.symbol("cmux_remote_shim_take_reply_region") else { return nil }
            // SAFETY: the symbols are the C functions of remote_shim_runtime.h with these signatures, in a
            // dylib that is never closed.
            self.print = unsafe unsafeBitCast(print, to: PrintFn.self)
            takeRegion = unsafe unsafeBitCast(take, to: TakeRegionFn.self)
        }

        init(print: PrintFn, takeRegion: TakeRegionFn) {
            self.print = print
            self.takeRegion = takeRegion
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
    /// The window whose print panel shows now, until the panel ends.
    private(set) weak var panelWindow: NSWindow?
    /// The remote dylib's calls, bound at the first print (one dylib for every host).
    private var calls: Calls?
    private let showPanel: ShowPanel

    init(calls: Calls? = nil, showPanel: @escaping ShowPanel = { BrowserPagePrint.printPDF($0, on: $1, done: $2) }) {
        self.calls = calls
        self.showPanel = showPanel
    }

    /// Asks the attached host for `browser`'s page as a PDF on the print panel's paper; the panel shows
    /// on `window` once the PDF comes. False when nothing was sent (no host attached, a host that does not
    /// print, or `window` already shows a sheet), as for a page that cannot print.
    func print(_ browser: Int32, on window: NSWindow, runtime: CEFRuntime) -> Bool {
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
                return
            }
            self.show(result, region: region, on: window)
        }
        return true
    }

    /// Ends the print panel showing now, as its Cancel would (`debug.cef` `print_cancel`). False when none shows.
    func cancelPanel() -> Bool {
        guard let window = panelWindow, let sheet = window.attachedSheet else { return false }
        window.endSheet(sheet, returnCode: .cancel)
        return true
    }

    var report: CEFHostPagePrintReport {
        CEFHostPagePrintReport(asked: asked, printed: printed, shown: shown, failed: failed, showing: panelWindow?.attachedSheet != nil)
    }

    private func boundCalls(_ hostStart: CEFHostStart) -> Calls? {
        if let calls { return calls }
        guard let remote = hostStart.remote else { return nil }
        calls = Calls(remote)
        return calls
    }

    private func show(_ result: Result<ChromiumHostPrintedPDF, CEFHostReplyError>, region: Int32, on window: NSWindow?) {
        var data: Data?
        if region >= 0 {
            if case .success(let reply) = result, reply.printed { data = Self.mappedPDF(region, count: reply.size) }
            // The mapping stays valid once the descriptor is closed.
            Darwin.close(region)
        }
        guard let data, let document = PDFDocument(data: data) else {
            failed += 1
            return
        }
        printed += 1
        // The window may have closed, or shown another sheet, while the host printed.
        guard let window, showPanel(document, window, { [weak self] in self?.panelWindow = nil }) else {
            failed += 1
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
