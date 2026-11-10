import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextHome
import CmuxNextPages
import CmuxNextSettings
import CmuxNextTestSupport
import Foundation
import Testing

/// A toast host that counts the times the window's avoidance link moves its toasts.
@MainActor
private final class ReanchorSpy: CmuxToastReanchoring {
    var reanchors = 0
    func reanchor(in window: NSWindow) { reanchors += 1 }
}

/// The view that holds a Messages page, as HomeMessagesPage and HomeConversationPage do: it avoids
/// the page's reported compose bar.
@MainActor
private final class HolderView: NSView, CmuxToastAvoiding {
    let avoidance = HomePageToastAvoidance()
    override var isFlipped: Bool { true }
    var toastAvoidanceRect: NSRect { avoidance.rect(in: self) }
}

/// A toast never covers a Messages page's compose bar, and the bar never moves for a toast (Leo,
/// 2026-11-07: "The composer should never ever rise up because there's some sort of ... tooltip type
/// thing"). The page reports the bar's box (`cmux.home.messages.toastAvoidance`); the view that holds
/// the page avoids it and the toast host lifts its toasts above it (AgentPaneToastAvoidanceTests' case).
@MainActor @Suite(.closesItsWindows)
struct HomePageToastAvoidanceTests {
    /// A page box (CSS pixels, top-left) in view points: scaled by the zoom, flipped or from the bottom.
    @Test func aBoxConvertsWithThePageZoom() {
        let box = CGRect(x: 20, y: 600, width: 860, height: 90)
        let page = CGRect(x: 10, y: 0, width: 1800, height: 1400)
        #expect(HomePageToastAvoidance.viewRect(box, page: page, zoom: 2, flipped: true) == CGRect(x: 50, y: 1200, width: 1720, height: 180))
        #expect(HomePageToastAvoidance.viewRect(box, page: page, zoom: 2, flipped: false) == CGRect(x: 50, y: 20, width: 1720, height: 180))
        // A zoom below a quarter counts as a quarter.
        #expect(HomePageToastAvoidance.viewRect(box, page: page, zoom: 0, flipped: true).width == 215)
    }

    /// The op keeps one box or none; more than one, a bad box or another op is refused or passed on.
    @Test func theOpKeepsOneBoxAndRefusesBadOnes() throws {
        let avoidance = HomePageToastAvoidance()
        #expect(try avoidance.call("selected", [:]) == nil)
        let one: JSONValue = .object(["left": .number(20), "top": .number(600), "right": .number(880), "bottom": .number(690)])
        #expect(try avoidance.call(HomePageToastAvoidance.op, ["rects": .array([one])]) == .null)
        #expect(avoidance.box == CGRect(x: 20, y: 600, width: 860, height: 90))
        #expect(throws: PageError.self) { try avoidance.call(HomePageToastAvoidance.op, ["rects": .array([one, one])]) }
        let inverted: JSONValue = .object(["left": .number(880), "top": .number(600), "right": .number(20), "bottom": .number(690)])
        #expect(throws: PageError.self) { try avoidance.call(HomePageToastAvoidance.op, ["rects": .array([inverted])]) }
        #expect(throws: PageError.self) { try avoidance.call(HomePageToastAvoidance.op, [:]) }
        #expect(avoidance.box == CGRect(x: 20, y: 600, width: 860, height: 90), "a refused report changed the box")
        _ = try avoidance.call(HomePageToastAvoidance.op, ["rects": .array([])])
        #expect(avoidance.box == nil)
    }

    /// A toast over the page rests above its reported bar, which stays where it is; the window's
    /// toasts are told when the bar comes, when the page hides and shows again, and when it goes.
    @Test func aToastRestsAboveTheComposeBar() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("home-toast-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("<!doctype html><title>Messages</title>".utf8).write(to: root.appendingPathComponent("index.html"))
        let descriptor = PageDescriptor(id: "test.home-toast-avoidance", resource: "home-toast-avoidance", namespaces: [])
        let page = try #require(PageWebView(descriptor: descriptor, root: root, testRoot: true, routes: [], route: "#/", chromium: nil))
        defer { page.close() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        defer {
            window.isReleasedWhenClosed = false
            window.close()
        }
        let content = try #require(window.contentView)
        let workspace = NSView(frame: content.bounds)
        content.addSubview(workspace)
        let holder = HolderView(frame: workspace.bounds)
        page.frame = holder.bounds
        holder.addSubview(page)
        holder.avoidance.attach(holder, page: page)
        workspace.addSubview(holder)
        let spy = ReanchorSpy()
        CmuxToastAvoidance.register(spy, in: window)
        defer { CmuxToastAvoidance.unregister(spy, from: window) }
        let bounds = content.bounds
        #expect(CmuxToastAvoidance.floor(width: 400, in: bounds, window: window) == bounds.minY)

        // The bar 90 px tall, its bottom 10 px over the page's foot.
        let zoom = CGFloat(page.pageZoom)
        let pageHeight = page.bounds.height / max(0.25, zoom)
        var before = spy.reanchors
        holder.avoidance.report(CGRect(x: 20, y: pageHeight - 100, width: 860, height: 90))
        for _ in 0..<20 where spy.reanchors == before { await Task.yield() }
        #expect(spy.reanchors > before, "the toast host was not told the bar came")
        let bar = holder.convert(holder.toastAvoidanceRect, to: nil)
        #expect(abs(bar.height - 90 * max(0.25, zoom)) < 1)
        #expect(abs(bar.minY - 10 * max(0.25, zoom)) < 1)
        #expect(CmuxToastAvoidance.floor(width: 400, in: bounds, window: window) >= bar.maxY + CmuxToastAvoidance.avoidanceGap - 0.5,
                "the toast covers the compose bar")
        #expect(holder.convert(holder.toastAvoidanceRect, to: nil) == bar, "the bar moved for a toast")

        // A workspace switch hides an ancestor and moves no frame: the toast comes down, and goes
        // back above the bar when the page shows again.
        workspace.isHidden = true
        #expect(CmuxToastAvoidance.floor(width: 400, in: bounds, window: window) < bar.maxY, "a hidden page still held the toast up")
        before = spy.reanchors
        workspace.isHidden = false
        for _ in 0..<20 where spy.reanchors == before { await Task.yield() }
        #expect(spy.reanchors > before, "the toast host was not told the page showed again")

        // The page reports no bar: the toast rests at the window's foot.
        before = spy.reanchors
        holder.avoidance.report(nil)
        for _ in 0..<20 where spy.reanchors == before { await Task.yield() }
        #expect(spy.reanchors > before)
        #expect(holder.toastAvoidanceRect.isEmpty)
        #expect(CmuxToastAvoidance.floor(width: 400, in: bounds, window: window) == bounds.minY)
    }
}
