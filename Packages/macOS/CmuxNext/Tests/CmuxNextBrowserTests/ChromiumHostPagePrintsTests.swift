import AppKit
@testable import CmuxNextBrowser
import CmuxNextSharedRegionC
import Darwin
import Foundation
import PDFKit
import Testing

/// Task p01-process-065 (feature `chromiumHostPrint`, ``ChromiumHostPagePrints``): File > Print… of a
/// host page asks the host for its PDF at the print panel's paper, and the REPLY's sealed region becomes
/// the PDF cmux prints; a page that did not print, a gone host or a gone window shows no panel and leaks
/// no descriptor. A page's own window.print() (PAGE_PRINT) prints the same way and its request ends only
/// when the panel ends, or at once when no panel can show. The host's side (the op, its region with the REPLY) is
/// ChromiumHost/tests/host_print_test.cpp.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct ChromiumHostPagePrintsTests {
    @Test func aPrintAsksTheHostAtThePanelsPaper() async throws {
        let (runtime, prints) = try await PrintHarness.hostRuntime()
        let window = PrintHarness.window()

        #expect(prints.print(7, on: window, runtime: runtime))

        let paper = NSPrintInfo.shared.paperSize
        #expect(PrintSpy.calls == ["print_to_pdf 7 \(Double(paper.width) / 72) \(Double(paper.height) / 72)"])
        #expect(prints.report == CEFHostPagePrintReport(asked: 1, printed: 0, shown: 0, failed: 0, showing: false))
    }

    @Test func aHostThatDoesNotPrintIsNotAsked() async throws {
        let (runtime, prints) = try await PrintHarness.hostRuntime()
        PrintSpy.printResult = 0

        #expect(!prints.print(7, on: PrintHarness.window(), runtime: runtime), "nothing was sent: the print cannot show")
        #expect(prints.report.asked == 0)
    }

    @Test func aPageThatDidNotPrintShowsNoPanel() async throws {
        let (runtime, prints) = try await PrintHarness.hostRuntime()
        let window = PrintHarness.window()
        #expect(prints.print(7, on: window, runtime: runtime))

        try PrintHarness.deliver(try #require(PrintSpy.tokens.last), PrintHarness.reply(0, 0))

        #expect(prints.report == CEFHostPagePrintReport(asked: 1, printed: 0, shown: 0, failed: 1, showing: false))
        #expect(window.attachedSheet == nil)
    }

    /// The region comes with the REPLY and is taken in its turn: mapped into the PDF the panel shows on
    /// the page's window, then closed.
    @Test func thePrintedPDFShowsOnThePagesWindow() async throws {
        let panels = PanelRecorder()
        let (runtime, prints) = try await PrintHarness.hostRuntime(panels)
        let window = PrintHarness.window()
        #expect(prints.print(7, on: window, runtime: runtime))
        let pdf = Array(PrintHarness.onePagePDF.utf8)
        let region = try #require(PrintHarness.region(pdf))
        PrintSpy.region = region

        try PrintHarness.deliver(try #require(PrintSpy.tokens.last), PrintHarness.reply(1, Int64(pdf.count)))

        #expect(PrintSpy.region == -1, "the REPLY's callback took the region")
        #expect(fcntl(region, F_GETFD) == -1, "and closed it once mapped")
        #expect(panels.pages == [1], "the host's one-page PDF")
        #expect(panels.windows.first === window, "on the page's window")
        #expect(prints.report == CEFHostPagePrintReport(asked: 1, printed: 1, shown: 1, failed: 0, showing: false))
        #expect(prints.panelWindow === window)
        panels.endAll()
        #expect(prints.panelWindow == nil, "the panel's end forgets its window")
    }

    /// A window that already shows a sheet when the PDF comes shows no panel; the region still closes.
    @Test func aPanelThatCannotShowFails() async throws {
        let panels = PanelRecorder()
        panels.shows = false
        let (runtime, prints) = try await PrintHarness.hostRuntime(panels)
        #expect(prints.print(7, on: PrintHarness.window(), runtime: runtime))
        let pdf = Array(PrintHarness.onePagePDF.utf8)
        let region = try #require(PrintHarness.region(pdf))
        PrintSpy.region = region

        try PrintHarness.deliver(try #require(PrintSpy.tokens.last), PrintHarness.reply(1, Int64(pdf.count)))

        #expect(fcntl(region, F_GETFD) == -1)
        #expect(prints.report == CEFHostPagePrintReport(asked: 1, printed: 1, shown: 0, failed: 1, showing: false))
    }

    /// A host that exits before it answers fails the print: no panel, and nothing is left waiting.
    @Test func aHostThatGoesFailsThePrint() async throws {
        let (runtime, prints) = try await PrintHarness.hostRuntime()
        #expect(prints.print(7, on: PrintHarness.window(), runtime: runtime))

        runtime.hostGone()

        #expect(prints.report == CEFHostPagePrintReport(asked: 1, printed: 0, shown: 0, failed: 1, showing: false))
        #expect(PrintSpy.takes == 1, "the failure's turn still asked for (and found no) region")
    }

    /// Each host's attach (`CEFHostStart.attached()`) turns page prints on, so a page's own window.print()
    /// comes to cmux (PAGE_PRINT), on the first host and on the one after it ended.
    @Test func theAttachTurnsPagePrintsOn() async throws {
        PrintSpy.reset()
        let prints = ChromiumHostPagePrints()
        let host = try await PrintHarness.attachedHost(prints)
        #expect(PrintSpy.calls == ["set_page_prints 1"], "the first attach")
        #expect(!prints.report.pageHook, "a host whose fork lacks the hook (p01-process-242) says so")

        host.hostEnded()
        PrintSpy.pageHook = 1
        guard case .success = await host.attached() else { throw BrowserTabError.closed }

        #expect(PrintSpy.calls == ["set_page_prints 1", "set_page_prints 1"], "the next host's attach")
        #expect(prints.report.pageHook, "the next host has the hook")
    }

    /// A page print ends only on the host it came from: once that host ended, a panel that ends later
    /// sends nothing, since the next host hands out the same request ids for its own pages.
    @Test func aPagePrintOfAGoneHostDoesNotEndTheNextHostsRequest() async throws {
        let panels = PanelRecorder()
        let (runtime, prints) = try await PrintHarness.hostRuntime(panels)
        let host = try #require(runtime.hostStart)
        prints.pageAsked(5, browser: 7, on: PrintHarness.window(), runtime: runtime)
        let pdf = Array(PrintHarness.onePagePDF.utf8)
        PrintSpy.region = try #require(PrintHarness.region(pdf))
        try PrintHarness.deliver(try #require(PrintSpy.tokens.last), PrintHarness.reply(1, Int64(pdf.count)))
        #expect(panels.windows.count == 1, "host A's page print shows its panel")

        host.hostEnded()
        guard case .success = await host.attached() else { throw BrowserTabError.closed }
        panels.endAll()

        #expect(PrintSpy.ends.isEmpty, "host B gets no end for host A's request 5")
        #expect(prints.report.pageEnded == 1, "the page print still ended")
    }

    /// File > Print… of a host page goes to the host's PDF and cmux's panel, never to Chromium's preview
    /// (`cmux_shim_print`); without page prints it opens the preview as before.
    @Test func fileMenuPrintOfAHostPagePrintsToPDF() async throws {
        let (runtime, _) = try await PrintHarness.hostRuntime()
        let tab = HostRepliesHarness.tab(in: HostRepliesHarness.pane(runtime, profile: .default).0)
        tab.attach(browser: 7)
        let window = PrintHarness.window()
        // Hidden in the window: the tab does not show its page, it only has a window.
        tab.contentView.isHidden = true
        window.contentView?.addSubview(tab.contentView)
        PrintSpy.calls = []

        #expect(BrowserPagePrint(tab).run())

        #expect(PrintSpy.calls.count == 1 && PrintSpy.calls.first?.hasPrefix("print_to_pdf 7 ") == true,
                "the host prints the page to PDF, and Chromium's preview never opens: \(PrintSpy.calls)")

        runtime.hostStart?.pagePrints = nil
        PrintSpy.calls = []
        #expect(BrowserPagePrint(tab).run())
        #expect(PrintSpy.calls == ["shim_print 7"], "without page prints, Chromium's preview")
    }

    /// A page's window.print() prints as File > Print… does, and its request ends (the page's
    /// window.print() returns) only when the panel ends.
    @Test func aPagePrintEndsWhenItsPanelEnds() async throws {
        let panels = PanelRecorder()
        let (runtime, prints) = try await PrintHarness.hostRuntime(panels)
        let window = PrintHarness.window()

        prints.pageAsked(1 << 40, browser: 7, on: window, runtime: runtime)

        #expect(PrintSpy.calls.first?.hasPrefix("print_to_pdf 7 ") == true, "the host prints the page to PDF")
        let pdf = Array(PrintHarness.onePagePDF.utf8)
        PrintSpy.region = try #require(PrintHarness.region(pdf))
        try PrintHarness.deliver(try #require(PrintSpy.tokens.last), PrintHarness.reply(1, Int64(pdf.count)))
        #expect(panels.windows.first === window, "the panel shows on the page's window")
        #expect(PrintSpy.ends.isEmpty, "the page's window.print() waits while the panel shows")

        panels.endAll()

        #expect(PrintSpy.ends == [1 << 40], "the panel's end ends the request")
        #expect(prints.report == CEFHostPagePrintReport(asked: 1, printed: 1, shown: 1, failed: 0, showing: false,
                                                       pageAsked: 1, pageEnded: 1))
    }

    /// A page print with no panel to show ends at once or with its PDF: the page's window.print() never
    /// waits for good.
    @Test func aPagePrintWithNoPanelEnds() async throws {
        let (runtime, prints) = try await PrintHarness.hostRuntime()

        prints.pageAsked(3, browser: 7, on: nil, runtime: runtime)
        #expect(PrintSpy.ends == [3] && PrintSpy.tokens.isEmpty, "a page with no window: ended at once, nothing printed")

        prints.pageAsked(4, browser: 7, on: PrintHarness.window(), runtime: runtime)
        try PrintHarness.deliver(try #require(PrintSpy.tokens.last), PrintHarness.reply(0, 0))
        #expect(PrintSpy.ends == [3, 4], "a page that did not print: ended with its REPLY")

        PrintSpy.printResult = 0
        prints.pageAsked(5, browser: 7, on: PrintHarness.window(), runtime: runtime)
        #expect(PrintSpy.ends == [3, 4, 5], "a host that cannot print: ended at once")

        PrintSpy.printResult = 1
        prints.pageAsked(6, browser: 7, on: PrintHarness.window(), runtime: runtime)
        runtime.hostGone()
        #expect(PrintSpy.ends == [3, 4, 5, 6], "a host that goes: ended")
        #expect(prints.report.pageAsked == 4 && prints.report.pageEnded == 4)
    }

    /// PAGE_PRINT decodes and reaches the page prints through the runtime: a page with no tab ends at once.
    @Test func aPagePrintEventReachesThePagePrints() async throws {
        #expect(CEFShimEvent(kind: 61, browser: 7, request: 0, a: 1 << 40, b: 0, s1: "", s2: "") == .pagePrint(browser: 7, request: 1 << 40))
        #expect(CEFShimEvent(kind: 61, browser: 7, request: 0, a: 0, b: 0, s1: "", s2: "") == .unknown(kind: 61), "request 0 is no request")
        let (runtime, prints) = try await PrintHarness.hostRuntime()

        runtime.dispatch(.pagePrint(browser: 9, request: 12))

        #expect(prints.report.pageAsked == 1 && PrintSpy.ends == [12])
    }

    @Test func theReplyIsPrintedAndSize() throws {
        func decode(_ result: Int32, _ size: Int64) -> ChromiumHostPrintedPDF? {
            guard var fields = try? CEFHostReplyFields(encoded: PrintHarness.reply(result, size)) else { return nil }
            return try? ChromiumHostPrintedPDF(reply: &fields)
        }
        #expect(decode(1, 4096) == ChromiumHostPrintedPDF(printed: true, size: 4096))
        #expect(decode(0, 0) == ChromiumHostPrintedPDF(printed: false, size: 0))
        #expect(decode(1, 0) == nil, "a printed page has bytes")
        #expect(decode(0, 12) == nil, "an unprinted one has none")
        #expect(decode(2, 12) == nil)
        #expect(decode(1, Int64(ChromiumHostPrintedPDF.maxBytes) + 1) == nil, "past the channel's shared bytes")
    }

    @Test func aRegionMapsWithoutACopy() throws {
        let bytes = Array("%PDF-1.4 region bytes".utf8)
        let region = try #require(PrintHarness.region(bytes))
        defer { close(region) }

        #expect(ChromiumHostPagePrints.mappedPDF(region, count: bytes.count).map(Array.init) == bytes)
        #expect(ChromiumHostPagePrints.mappedPDF(region, count: bytes.count + 1) == nil, "more than the region holds")
        #expect(ChromiumHostPagePrints.mappedPDF(region, count: 0) == nil)

        var pipe: [Int32] = [0, 0]
        #expect(Darwin.pipe(&pipe) == 0)
        defer { pipe.forEach { close($0) } }
        #expect(ChromiumHostPagePrints.mappedPDF(pipe[0], count: 1) == nil, "a descriptor that is not a sealed region")
    }
}

/// Host mode against ``PrintSpy`` for ``ChromiumHostPagePrintsTests``.
@MainActor enum PrintHarness {
    /// One page, US Letter; CoreGraphics rebuilds the missing cross-reference table.
    static let onePagePDF = """
        %PDF-1.4
        1 0 obj <</Type /Catalog /Pages 2 0 R>> endobj
        2 0 obj <</Type /Pages /Kids [3 0 R] /Count 1>> endobj
        3 0 obj <</Type /Page /Parent 2 0 R /MediaBox [0 0 612 792]>> endobj
        trailer <</Root 1 0 R>>
        %%EOF
        """

    /// A runtime in host mode whose page prints show their panels through `panels`; the attach's calls are forgotten.
    static func hostRuntime(_ panels: PanelRecorder = PanelRecorder()) async throws -> (CEFRuntime, ChromiumHostPagePrints) {
        PrintSpy.reset()
        let runtime = CEFRuntime(shim: try CEFShimLibrary.resolving(PrintSpy.symbol), storage: HostRepliesHarness.storage())
        // Tabs and panes hold the runtime unowned and may schedule work past the test.
        _ = Unmanaged.passRetained(runtime)
        let prints = ChromiumHostPagePrints(showPanel: { document, window, done in panels.show(document, on: window, done: done) })
        runtime.hostStart = try await attachedHost(prints)
        PrintSpy.calls = []
        return (runtime, prints)
    }

    /// A host start with `prints` as the app sets it (`CEFRuntime.adoptHost`: before the attach), attached to ``PrintSpy``.
    static func attachedHost(_ prints: ChromiumHostPagePrints) async throws -> CEFHostStart {
        let host = CEFHostStart(supervisor: OneSpyHost(), open: { _ in
            do throws(CEFShimLibrary.LoadError) { return .success(try CEFRemoteShim.make(symbol: PrintSpy.symbol, expected: PrintSpy.abi)) } catch { return .failure(.shim(error)) }
        })
        host.pagePrints = prints
        guard case .success = await host.attached() else { throw BrowserTabError.closed }
        return host
    }

    /// A window never ordered in, released when the test lets it go.
    static func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    /// A kOpPrintToPdf REPLY body: i32 result, i64 size (EncodeFields, little-endian).
    static func reply(_ result: Int32, _ size: Int64) -> [UInt8] {
        var body: [UInt8] = [1, 0, 4, 0]
        body += withUnsafeBytes(of: result.littleEndian, Array.init)
        body += [2, 0, 8, 0]
        body += withUnsafeBytes(of: size.littleEndian, Array.init)
        return body
    }

    /// A sealed region holding `bytes`, as the host's CreateSharedRegion makes one.
    static func region(_ bytes: [UInt8]) -> Int32? {
        let fd = bytes.withUnsafeBytes { cmux_shared_region_create($0.baseAddress, $0.count) }
        return fd >= 0 ? fd : nil
    }

    static func deliver(_ token: UInt32, _ fields: [UInt8]) throws {
        let sink = try #require(PrintSpy.replySink)
        let reply = try #require(sink.reply)
        fields.withUnsafeBytes { reply(sink.context, token, $0.baseAddress, $0.count) }
    }
}

/// The print panels a test's prints show: each PDF's page count and window, and each panel's end.
@MainActor final class PanelRecorder {
    var shows = true
    private(set) var pages: [Int] = []
    private(set) var windows: [NSWindow] = []
    private var ends: [@MainActor () -> Void] = []

    func show(_ document: PDFDocument, on window: NSWindow, done: @escaping @MainActor () -> Void) -> Bool {
        guard shows else { return false }
        pages.append(document.pageCount)
        windows.append(window)
        ends.append(done)
        return true
    }

    /// Every panel ends, as its Cancel would.
    func endAll() {
        let ends = ends
        self.ends = []
        for end in ends { end() }
    }
}

/// The remote dylib for these tests: attach says hello at once, set_reply keeps the REPLY sink,
/// `print_to_pdf` records its call, makes the next token current and answers ``printResult``, and
/// `take_reply_region` hands over ``region`` once, `set_page_prints` records its call and answers ``pageHook``,
/// `page_print_end` records its request in ``ends``, and the in-process `cmux_shim_print` (Chromium's preview) records its call.
/// Every other function returns 0.
nonisolated enum PrintSpy {
    static let abi = "print-spy-abi"
    // crash-allow: test-only spy state, read and written on the main thread by a serialized suite and the C stand-ins it calls there
    nonisolated(unsafe) static var lastToken: UInt32 = 0
    // crash-allow: test-only spy state (see lastToken)
    nonisolated(unsafe) static var tokens: [UInt32] = []
    // crash-allow: test-only spy state (see lastToken)
    nonisolated(unsafe) static var calls: [String] = []
    // crash-allow: test-only spy state (see lastToken)
    nonisolated(unsafe) static var printResult: Int32 = 1
    // crash-allow: test-only spy state (see lastToken)
    nonisolated(unsafe) static var region: Int32 = -1
    // crash-allow: test-only spy state (see lastToken)
    nonisolated(unsafe) static var takes = 0
    // crash-allow: test-only spy state (see lastToken)
    nonisolated(unsafe) static var ends: [Int64] = []
    // crash-allow: test-only spy state (see lastToken)
    nonisolated(unsafe) static var pageHook: Int32 = 0
    // crash-allow: test-only spy state (see lastToken)
    nonisolated(unsafe) static var replySink: (context: UnsafeMutableRawPointer?, reply: CEFRemoteShim.ReplyFn?)?
    // crash-allow: a C string made once and never freed, read only
    nonisolated(unsafe) private static let abiCString = strdup(abi)

    static func reset() {
        lastToken = 0
        tokens = []
        calls = []
        printResult = 1
        region = -1
        takes = 0
        ends = []
        pageHook = 0
        replySink = nil
    }

    static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        let abiID: @convention(c) () -> UnsafePointer<CChar>? = { UnsafePointer(PrintSpy.abiCString) }
        let attach: CEFRemoteShim.AttachFn = { _, _, _, context, hello in
            hello?(context, 1, nil)
            return 1
        }
        let detach: CEFRemoteShim.DetachFn = {}
        let setReply: CEFRemoteShim.SetReplyFn = { context, reply in PrintSpy.replySink = (context, reply) }
        let lastReplyToken: CEFRemoteShim.LastReplyTokenFn = { PrintSpy.lastToken }
        let printToPDF: ChromiumHostPagePrints.Calls.PrintFn = { browser, width, height in
            PrintSpy.calls.append("print_to_pdf \(browser) \(width) \(height)")
            guard PrintSpy.printResult == 1 else {
                PrintSpy.lastToken = 0
                return 0
            }
            PrintSpy.lastToken = 100 + UInt32(PrintSpy.tokens.count)
            PrintSpy.tokens.append(PrintSpy.lastToken)
            return 1
        }
        let takeRegion: ChromiumHostPagePrints.Calls.TakeRegionFn = {
            PrintSpy.takes += 1
            defer { PrintSpy.region = -1 }
            return PrintSpy.region
        }
        let setPagePrints: ChromiumHostPagePrints.Calls.SetPagePrintsFn = { enabled in
            PrintSpy.calls.append("set_page_prints \(enabled)")
            return PrintSpy.pageHook
        }
        let endPagePrint: ChromiumHostPagePrints.Calls.EndPagePrintFn = { request in
            PrintSpy.ends.append(request)
            return 1
        }
        let shimPrint: @convention(c) (Int32) -> Int32 = { browser in
            PrintSpy.calls.append("shim_print \(browser)")
            return 1
        }
        let nothing: @convention(c) () -> Int = { 0 }
        return switch name {
        case "cmux_shim_abi_id": unsafeBitCast(abiID, to: UnsafeMutableRawPointer.self)
        case "cmux_remote_shim_attach": unsafeBitCast(attach, to: UnsafeMutableRawPointer.self)
        case "cmux_remote_shim_detach": unsafeBitCast(detach, to: UnsafeMutableRawPointer.self)
        case "cmux_remote_shim_set_reply": unsafeBitCast(setReply, to: UnsafeMutableRawPointer.self)
        case "cmux_remote_shim_last_reply_token": unsafeBitCast(lastReplyToken, to: UnsafeMutableRawPointer.self)
        case "cmux_remote_shim_print_to_pdf": unsafeBitCast(printToPDF, to: UnsafeMutableRawPointer.self)
        case "cmux_remote_shim_take_reply_region": unsafeBitCast(takeRegion, to: UnsafeMutableRawPointer.self)
        case "cmux_remote_shim_set_page_prints": unsafeBitCast(setPagePrints, to: UnsafeMutableRawPointer.self)
        case "cmux_remote_shim_page_print_end": unsafeBitCast(endPagePrint, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_print": unsafeBitCast(shimPrint, to: UnsafeMutableRawPointer.self)
        default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
        }
    }
}
