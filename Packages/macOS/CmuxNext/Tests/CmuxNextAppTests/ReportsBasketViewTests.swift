import AppKit
@testable import CmuxNextFeed
import CmuxNextTestSupport
import Foundation
import Testing

/// The Labs reports basket is AppKit (plans/cmux-next/no-swiftui-DESIGN.md rule 4): it builds no
/// hosting view, its rows follow clicks and the model, and a reply is sent once while in flight
/// and keeps its draft (and its id) when it was not sent.
@MainActor @Suite(.closesItsWindows) struct ReportsBasketViewTests {
    private let older = FeedReport(id: "r1", sender: "host/alpha", body: "first report",
                                   createdAt: Date(timeIntervalSince1970: 1_000))
    private let newer = FeedReport(id: "r2", sender: "host/beta", body: "second report",
                                   createdAt: Date(timeIntervalSince1970: 2_000))

    /// Answers the basket's replies when the test says so.
    @MainActor final class Host {
        var replies: [ReportReply] = []
        private var answer: CheckedContinuation<Bool, Never>?

        func send(_ reply: ReportReply) async -> Bool {
            replies.append(reply)
            return await withCheckedContinuation { answer = $0 }
        }

        func answer(_ sent: Bool) {
            answer?.resume(returning: sent)
            answer = nil
        }
    }

    private func shown(_ model: FeedModel, host: Host? = nil) -> (ReportsBasketView, NSWindow) {
        let view = ReportsBasketView(model: model, onReply: host.map { host in { await host.send($0) } })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        return (view, window)
    }

    /// Lets main-actor tasks run until `condition` holds (bounded).
    private func until(_ condition: () -> Bool) async {
        var tries = 0
        while !condition(), tries < 400 {
            tries += 1
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func subviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(subviews(of:))
    }

    @Test func theBasketBuildsNoHostingView() {
        let model = FeedModel(source: MockFeedSource())
        model.replaceReports([older, newer])
        let (view, window) = shown(model)
        defer { window.close() }
        // A SwiftUI hosting view (or any SwiftUI-made view) has a SwiftUI-mangled class name.
        let names = subviews(of: view).map { NSStringFromClass(type(of: $0)) }
        let swiftUI = names.filter { $0.contains("SwiftUI") }
        #expect(swiftUI.isEmpty, "SwiftUI views in the basket: \(swiftUI)")
        #expect(!view.rows.isEmpty)
    }

    @Test func theListAndTheDetailFillTheBasket() throws {
        let model = FeedModel(source: MockFeedSource())
        model.replaceReports([older, newer])
        let (view, window) = shown(model)
        defer { window.close() }
        let row = try #require(view.rows.first)
        let detail = try #require(view.detail)
        let list = row.convert(row.bounds, to: view)
        let side = detail.convert(detail.bounds, to: view)
        #expect(row.bounds.height > 20 && row.bounds.width > 300, "row \(row.bounds)")
        #expect((340...420).contains(list.maxX + 8), "the list column is 340-420 wide: row ends at \(list.maxX)")
        #expect(side.width >= 420 && side.height == view.bounds.height, "detail \(side) in \(view.bounds)")
        #expect(detail.field.frame.height > 0 && detail.replyButton.frame.width > 0)
    }

    @Test func aLongReportWrapsInsideItsPanes() throws {
        let model = FeedModel(source: MockFeedSource())
        let long = String(repeating: "a long line of report text that has to wrap ", count: 40)
        model.replaceReports([FeedReport(id: "r3", sender: "host/gamma", body: long, createdAt: Date(timeIntervalSince1970: 3_000))])
        let (view, window) = shown(model)
        defer { window.close() }
        let row = try #require(view.rows.first)
        let detail = try #require(view.detail)
        let labels = { (root: NSView) in self.subviews(of: root).compactMap { $0 as? NSTextField }.filter { !$0.isEditable } }
        for label in labels(row) { #expect(label.frame.maxX <= row.bounds.maxX + 0.5, "row label \(label.frame) in \(row.bounds)") }
        for label in labels(detail) {
            let frame = label.convert(label.bounds, to: detail)
            #expect(frame.maxX <= detail.bounds.maxX + 0.5, "detail label \(frame) in \(detail.bounds)")
        }
    }

    @Test func theNewestReportIsSelectedAndAClickSelectsAnother() throws {
        let model = FeedModel(source: MockFeedSource())
        model.replaceReports([older, newer])
        let (view, window) = shown(model)
        defer { window.close() }
        #expect(view.selected == "r2")
        #expect(view.detail?.item.id == "r2")
        #expect(view.rows.map(\.selected) == [true, false])
        let row = try #require(view.rows.last)
        #expect(row.accessibilityPerformPress())
        #expect(view.selected == "r1")
        #expect(view.detail?.item.id == "r1")
        #expect(view.rows.map(\.selected) == [false, true])
    }

    @Test func aReportThatArrivesGetsARow() async {
        let model = FeedModel(source: MockFeedSource())
        model.replaceReports([older])
        let (view, window) = shown(model)
        defer { window.close() }
        #expect(view.rows.map(\.item.id) == ["r1"])
        model.replaceReports([older, newer])
        await until { view.rows.count == 2 }
        #expect(view.rows.map(\.item.id) == ["r2", "r1"])
        #expect(view.selected == "r1", "an arriving report does not take the selection")
    }

    @Test func aReplyIsSentOnceAndARefusedOneKeepsItsDraftAndId() async throws {
        let model = FeedModel(source: MockFeedSource())
        model.replaceReports([newer])
        let host = Host()
        let (view, window) = shown(model, host: host)
        defer { window.close() }
        let detail = try #require(view.detail)
        #expect(!detail.replyButton.isEnabled, "an empty draft has nothing to send")
        detail.field.stringValue = "on it"
        detail.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: detail.field))
        #expect(detail.replyButton.isEnabled)

        detail.replyButton.performClick(nil)
        detail.replyButton.performClick(nil)
        view.send()
        await until { !host.replies.isEmpty }
        #expect(host.replies.count == 1)
        #expect(host.replies.first?.session == "host/beta")
        #expect(host.replies.first?.text == "on it")
        #expect(!detail.replyButton.isEnabled, "the button waits for the answer")

        host.answer(false)
        await until { view.sending.isEmpty }
        #expect(view.draft == "on it")
        #expect(detail.field.stringValue == "on it")
        #expect(view.notSent == "r2")
        #expect(detail.notSentLabel.superview?.isHidden == false)

        detail.replyButton.performClick(nil)
        await until { host.replies.count == 2 }
        #expect(host.replies.count == 2)
        #expect(host.replies[1].promptID == host.replies[0].promptID, "the same reply sent again keeps its id")
        #expect(detail.notSentLabel.superview?.isHidden == true)

        host.answer(true)
        await until { view.sending.isEmpty }
        #expect(view.draft == "")
        #expect(detail.field.stringValue == "")
        #expect(view.notSent == nil)
    }
}
