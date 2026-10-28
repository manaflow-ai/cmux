@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import CmuxNextSignposts
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing
import WebKit

/// The `webui.open` and `webui.scheme` trace points of a page (p13-webui 003): every open is one AB/AE pair
/// keyed by the page, its end names the engine that painted, and every scheme task leaves its B/E slices
/// balanced and tagged with the asking page.
@MainActor
struct PageWebUITraceTests {
    private let descriptor = PageDescriptor(id: "test.webui-trace", resource: "webui-trace", processGroup: .solo, namespaces: [])

    /// A page view writing to `recorder`; with `load`, it starts its first document in `chromium` (WebKit
    /// when nil). The configuration has no scheme handler, so a WebKit load never commits.
    private func page(_ recorder: PageTraceRecorder, load: Bool = false, pooled: Bool = false,
                      chromium: (any PageChromiumHosting)? = nil) -> PageWebView {
        let configuration = WKWebViewConfiguration()
        return PageWebView(descriptor: descriptor, configuration: configuration,
                           inputReadiness: PageInputReadiness(configuration: configuration), routes: [], route: nil,
                           options: .standard, surface: nil, dynamicResources: nil, pooled: pooled, load: load,
                           chromium: chromium, deadlines: .testing(), trace: recorder)
    }

    @Test func aNewViewPaintedInChromiumIsOneOpenEndingInChromium() async throws {
        let recorder = PageTraceRecorder()
        let hosting = FakeChromiumHosting()
        let view = page(recorder, load: true, chromium: hosting)
        view.chromiumDeadlines = LifecycleDeadlineRig.never
        await view.chromiumStart?.value
        let chromium = try #require(hosting.made.first)
        let painted: Bool? = await PageTestWait.value("paint") { done in
            view.whenPainted { done(true) }
            chromium.onEvent?(.devTools(FakeChromiumPage.bindingCall(["name": PagePaintProbe.handlerName, "body": 5])))
        }
        #expect(painted == true)
        let opens = recorder.records.filter { $0.name == .webuiOpen }
        #expect(opens.map(\.phase) == [.asyncBegin, .asyncEnd])
        #expect(opens.allSatisfy { $0.arg1 == view.traceID })
        #expect(opens.first.map { $0.arg0 & 0xff } == PageOpenKind.newView.rawValue)
        #expect(opens.last?.arg0 == PageOpenOutcome.paintedInChromium.rawValue)
        view.close()
        #expect(recorder.records.filter { $0.name == .webuiOpen }.count == 2, "close after the paint ended a second slice")
    }

    @Test func aChromiumFailureBeforeThePaintEndsTheSameOpenInWebKit() async throws {
        let recorder = PageTraceRecorder()
        let hosting = FakeChromiumHosting()
        hosting.fails = true
        let view = page(recorder, load: true, chromium: hosting)
        let start = try #require(view.chromiumStart)
        await start.value
        #expect(view.engineDecision == .webKit(.chromiumFailed))
        view.notePainted()
        let opens = recorder.records.filter { $0.name == .webuiOpen }
        #expect(opens.map(\.phase) == [.asyncBegin, .asyncEnd], "the WebKit reopen began a second open")
        #expect(opens.last?.arg0 == PageOpenOutcome.paintedInWebKit.rawValue)
        view.close()
    }

    @Test func aReloadIsItsOwnOpenAndJoinsAPendingOne() {
        let recorder = PageTraceRecorder()
        let view = page(recorder)
        #expect(recorder.records.isEmpty, "a view made without a load opened nothing")
        view.reload()
        view.reload()
        view.notePainted()
        view.reload()
        view.close()
        let opens = recorder.records.filter { $0.name == .webuiOpen }
        #expect(opens.map(\.phase) == [.asyncBegin, .asyncEnd, .asyncBegin, .asyncEnd])
        #expect(opens.filter { $0.phase == .asyncBegin }.allSatisfy { $0.arg0 == PageOpenKind.reload.rawValue })
        #expect(opens.filter { $0.phase == .asyncEnd }.map(\.arg0)
            == [PageOpenOutcome.paintedInWebKit.rawValue, PageOpenOutcome.closedBeforePaint.rawValue])
    }

    @Test func aClaimReplacesAnUnpaintedOpenAndACommitOpensANavigatedDocument() {
        let recorder = PageTraceRecorder()
        // A preload's first document (PageOpenRequest.parked) is a spare open.
        let view = page(recorder, load: true, pooled: true)
        view.traceOpenRequested(.claim)
        view.documentCommitted() // the claimed document's own commit: part of the claim's open
        view.notePainted()
        view.documentCommitted() // a document the page navigated to by itself
        view.close()
        let opens = recorder.records.filter { $0.name == .webuiOpen }
        #expect(opens.map(\.phase) == [.asyncBegin, .asyncEnd, .asyncBegin, .asyncEnd, .asyncBegin, .asyncEnd])
        // Bits 0-7 name the kind; a new view's begin carries its construction time above them.
        #expect(opens.filter { $0.phase == .asyncBegin }.map { $0.arg0 & 0xff }
            == [PageOpenKind.spare, .claim, .navigated].map(\.rawValue))
        #expect(opens.filter { $0.phase == .asyncEnd }.map(\.arg0)
            == [PageOpenOutcome.replaced, .paintedInWebKit, .closedBeforePaint].map(\.rawValue))
    }

    // MARK: scheme tasks

    @Test func aServedFileIsAStartTheReplyStepsAndAnAnswer() async throws {
        let rig = try SchemeRig()
        defer { rig.remove() }
        let task = try rig.task("/")
        let finished: Bool? = await PageTestWait.value("answer") { done in
            task.finished = done
            rig.handler.webView(rig.view.webView, start: task)
        }
        #expect(finished == true)
        let slices = try rig.recorder.schemeSlices()
        #expect(slices.map(\.part) == [0, 2, 2, 2, 1])
        #expect(slices.allSatisfy { $0.page == rig.view.traceID && $0.outcome == 0 })
        #expect(slices.last?.bytes == UInt64(task.bodyBytes))
        #expect(task.bodyBytes > 0)
    }

    @Test func aRefusedRequestFailsInItsStartTurn() throws {
        let rig = try SchemeRig()
        defer { rig.remove() }
        let task = try rig.task("/", method: "POST")
        var finished: Bool?
        task.finished = { finished = $0 }
        rig.handler.webView(rig.view.webView, start: task)
        #expect(finished == false)
        let slices = try rig.recorder.schemeSlices()
        #expect(slices.map(\.part) == [0])
        #expect(slices.first?.outcome == 1)
    }

    @Test func aMissingFileFailsInItsAnswerTurn() async throws {
        let rig = try SchemeRig()
        defer { rig.remove() }
        let task = try rig.task("/missing.js")
        let finished: Bool? = await PageTestWait.value("answer") { done in
            task.finished = done
            rig.handler.webView(rig.view.webView, start: task)
        }
        #expect(finished == false)
        let slices = try rig.recorder.schemeSlices()
        #expect(slices.map(\.part) == [0, 2, 2, 1])
        #expect(slices.map(\.outcome) == [0, 0, 0, 1])
    }

    @Test func aStoppedTaskGetsNoAnswerTurn() async throws {
        let rig = try SchemeRig()
        defer { rig.remove() }
        let task = try rig.task("/")
        var answered = false
        task.finished = { _ in answered = true }
        let replied: Bool? = await PageTestWait.value("reply") { done in
            // The reply's last step ends the task's work: a stopped task is not answered after it.
            rig.recorder.onEnd = { part in if part == 2, rig.recorder.ended(part: 2) == 3 { done(true) } }
            rig.handler.webView(rig.view.webView, start: task)
            rig.handler.webView(rig.view.webView, stop: task)
        }
        #expect(replied == true)
        #expect(!answered)
        #expect(try rig.recorder.schemeSlices().map(\.part) == [0, 2, 2, 2])
    }
}

/// A page, its root with an `index.html`, and a scheme handler for it, all writing to one recorder.
@MainActor
private struct SchemeRig {
    let recorder = PageTraceRecorder()
    let root: URL
    let handler: PageSchemeHandler
    let view: PageWebView
    private let descriptor = PageDescriptor(id: "test.webui-scheme", resource: "webui-scheme", processGroup: .solo, namespaces: [])

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("webui-scheme-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
        let handler = PageSchemeHandler(page: descriptor, root: root, devServer: nil, trace: recorder)
        handler.liveOverride = { WebDevOverride() }
        self.handler = handler
        let configuration = WKWebViewConfiguration()
        // A view of its own, so the task's page id is a live page's.
        view = PageWebView(descriptor: descriptor, configuration: configuration,
                           inputReadiness: PageInputReadiness(configuration: configuration), routes: [], route: nil,
                           options: .standard, surface: nil, dynamicResources: nil, pooled: false, load: false,
                           chromium: nil, deadlines: .testing(), trace: PageTraceRecorder())
    }

    func task(_ path: String, method: String = "GET") throws -> FakeSchemeTask {
        var request = URLRequest(url: try #require(URL(string: descriptor.origin + path)))
        request.httpMethod = method
        return FakeSchemeTask(request)
    }

    func remove() {
        view.close()
        try? FileManager.default.removeItem(at: root)
    }
}

/// A WebKit scheme task that records how it ended.
private final class FakeSchemeTask: NSObject, WKURLSchemeTask {
    let request: URLRequest
    /// Called once with true on `didFinish`, false on `didFailWithError`.
    var finished: (Bool) -> Void = { _ in }
    private(set) var bodyBytes = 0

    init(_ request: URLRequest) { self.request = request }

    func didReceive(_ response: URLResponse) {}
    func didReceive(_ data: Data) { bodyBytes += data.count }
    func didFinish() { finished(true) }
    func didFailWithError(_ error: any Error) { finished(false) }
}

/// The trace points a page or scheme handler wrote, in order (``PageTraceSink``).
@MainActor
final class PageTraceRecorder: PageTraceSink {
    enum Phase { case begin, end, asyncBegin, asyncEnd }

    struct Record {
        let phase: Phase
        let name: SignpostName
        let arg0: UInt64
        /// The second number; the async id on AB and AE.
        let arg1: UInt64
    }

    /// One B/E pair of `webui.scheme`: the begin's part and page, the end's outcome and bytes.
    struct SchemeSlice {
        let part: UInt64
        let page: UInt64
        let outcome: UInt64
        let bytes: UInt64
    }

    struct Unbalanced: Error {}

    private(set) var records: [Record] = []
    /// Runs after each B/E end with the part its begin named.
    var onEnd: ((UInt64) -> Void)?
    private var open: [UInt64] = []
    private var endedParts: [UInt64] = []

    @discardableResult
    func begin(_ name: SignpostName, arg0: UInt64, arg1: UInt64) -> Bool {
        records.append(Record(phase: .begin, name: name, arg0: arg0, arg1: arg1))
        open.append(arg0)
        return true
    }

    func end(_ name: SignpostName, arg0: UInt64, arg1: UInt64) {
        records.append(Record(phase: .end, name: name, arg0: arg0, arg1: arg1))
        guard let part = open.popLast() else { return }
        endedParts.append(part)
        onEnd?(part)
    }

    @discardableResult
    func asyncBegin(_ name: SignpostName, id: UInt64, arg0: UInt64) -> Bool {
        records.append(Record(phase: .asyncBegin, name: name, arg0: arg0, arg1: id))
        return true
    }

    func asyncEnd(_ name: SignpostName, id: UInt64, arg0: UInt64) {
        records.append(Record(phase: .asyncEnd, name: name, arg0: arg0, arg1: id))
    }

    /// How many B/E slices of `part` ended.
    func ended(part: UInt64) -> Int { endedParts.filter { $0 == part }.count }

    /// The `webui.scheme` records as slices; throws when a begin has no end right after it (they never nest).
    func schemeSlices() throws -> [SchemeSlice] {
        let scheme = records.filter { $0.name == .webuiScheme }
        guard scheme.count.isMultiple(of: 2) else { throw Unbalanced() }
        return try stride(from: 0, to: scheme.count, by: 2).map { index in
            let (begin, end) = (scheme[index], scheme[index + 1])
            guard begin.phase == .begin, end.phase == .end else { throw Unbalanced() }
            return SchemeSlice(part: begin.arg0, page: begin.arg1, outcome: end.arg0, bytes: end.arg1)
        }
    }
}
