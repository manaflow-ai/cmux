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
/// no descriptor. The host's side (the op, its region with the REPLY) is
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

    /// A runtime in host mode whose page prints show their panels through `panels`.
    static func hostRuntime(_ panels: PanelRecorder = PanelRecorder()) async throws -> (CEFRuntime, ChromiumHostPagePrints) {
        PrintSpy.reset()
        let runtime = CEFRuntime(shim: try CEFShimLibrary.resolving(PrintSpy.symbol), storage: HostRepliesHarness.storage())
        // Tabs and panes hold the runtime unowned and may schedule work past the test.
        _ = Unmanaged.passRetained(runtime)
        let host = CEFHostStart(supervisor: OneSpyHost(), open: { _ in
            do throws(CEFShimLibrary.LoadError) { return .success(try CEFRemoteShim.make(symbol: PrintSpy.symbol, expected: PrintSpy.abi)) } catch { return .failure(.shim(error)) }
        })
        guard case .success = await host.attached() else { throw BrowserTabError.closed }
        runtime.hostStart = host
        let prints = ChromiumHostPagePrints(showPanel: { document, window, done in panels.show(document, on: window, done: done) })
        host.pagePrints = prints
        return (runtime, prints)
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
/// `take_reply_region` hands over ``region`` once. Every other function returns 0.
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
        let nothing: @convention(c) () -> Int = { 0 }
        return switch name {
        case "cmux_shim_abi_id": unsafeBitCast(abiID, to: UnsafeMutableRawPointer.self)
        case "cmux_remote_shim_attach": unsafeBitCast(attach, to: UnsafeMutableRawPointer.self)
        case "cmux_remote_shim_detach": unsafeBitCast(detach, to: UnsafeMutableRawPointer.self)
        case "cmux_remote_shim_set_reply": unsafeBitCast(setReply, to: UnsafeMutableRawPointer.self)
        case "cmux_remote_shim_last_reply_token": unsafeBitCast(lastReplyToken, to: UnsafeMutableRawPointer.self)
        case "cmux_remote_shim_print_to_pdf": unsafeBitCast(printToPDF, to: UnsafeMutableRawPointer.self)
        case "cmux_remote_shim_take_reply_region": unsafeBitCast(takeRegion, to: UnsafeMutableRawPointer.self)
        default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
        }
    }
}
