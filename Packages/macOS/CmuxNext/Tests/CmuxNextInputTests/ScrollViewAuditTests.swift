import AppKit
import CmuxNextControl
@testable import CmuxNextInputDiagnostics
import Foundation
import SwiftUI
import Testing

/// A private document view class: `String(reflecting:)` names it with a launch-dependent
/// `(unknown context at $...)` segment.
private final class PrivateDocument: NSView {}

/// `debug.input scroll_views`: the audit lists every scroll view under a window with
/// its classes, AppKit's responsive-scrolling flags and which views override `scrollWheel(_:)`, finds
/// SwiftUI hosting, keeps a stable JSON schema and stable class names, and reads only when asked.
@MainActor @Suite
struct ScrollViewAuditTests {
    final class WheelScrollView: NSScrollView {
        override func scrollWheel(with event: NSEvent) { super.scrollWheel(with: event) }
    }

    /// Overrides `scrollWheel(_:)`, calls super and opts back in, as p03-rendering-110's
    /// SidebarScrollView and PaletteListView do.
    final class OptInWheelScrollView: NSScrollView {
        override class var isCompatibleWithResponsiveScrolling: Bool { true }
        override func scrollWheel(with event: NSEvent) { super.scrollWheel(with: event) }
    }

    final class FrameScrollView: NSScrollView {}

    final class WheelDocument: NSView {
        override func scrollWheel(with event: NSEvent) { super.scrollWheel(with: event) }
    }

    final class DrawingDocument: NSView {
        override class var isCompatibleWithResponsiveScrolling: Bool { false }
        override func draw(_ dirtyRect: NSRect) {}
    }

    final class IncompatibleNonDrawingDocument: NSView {
        override class var isCompatibleWithResponsiveScrolling: Bool { false }
    }

    final class CompatibleDrawingDocument: NSView {
        override class var isCompatibleWithResponsiveScrolling: Bool { true }
        override func draw(_ dirtyRect: NSRect) {}
    }

    static func scrollView(_ scrollView: NSScrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 100, height: 100)),
                           document: NSView?) -> NSScrollView {
        scrollView.documentView = document
        return scrollView
    }

    static func root(_ views: NSView..., number: Int = 7) -> DebugInputScrollViews.WindowRoot {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        for view in views { root.addSubview(view) }
        return DebugInputScrollViews.WindowRoot(number: number, className: "NSWindow", visible: true, root: root)
    }

    @Test func aPlainScrollViewIsResponsive() throws {
        let audit = DebugInputScrollViews(auditing: [Self.root(Self.scrollView(document: NSView()))])
        let row = try #require(audit.rows.first)
        #expect(audit.rows.count == 1)
        #expect(row.window == 7)
        #expect(row.scrollViewClass == "NSScrollView")
        #expect(row.clipViewClass == "NSClipView")
        #expect(row.documentViewClass == "NSView")
        #expect(row.documentViewOverridesDraw == false)
        #expect(row.scrollWheelOverrides.isEmpty)
        #expect(row.swiftUIHosted == false)
        #expect(row.responsive)
        #expect(audit.notResponsive == 0)
    }

    /// AppKit's default `+[NSScrollView isCompatibleWithResponsiveScrolling]` is NO for a subclass that
    /// overrides `scrollWheel(_:)`; the override itself is only listed.
    @Test func aScrollWheelOverrideIsNamedAndCountsOnlyThroughTheClassFlag() throws {
        let subclass = Self.scrollView(WheelScrollView(frame: NSRect(x: 0, y: 0, width: 100, height: 100)), document: NSView())
        let document = Self.scrollView(document: WheelDocument())
        let audit = DebugInputScrollViews(auditing: [Self.root(subclass, document)])
        #expect(audit.rows.map(\.scrollWheelOverrides) == [["scroll_view"], ["document_view"]])
        #expect(audit.rows.map(\.scrollViewCompatible) == [false, true])
        #expect(audit.rows.map(\.responsive) == [false, true])
        #expect(audit.notResponsive == 1)
        #expect(audit.rows[0].scrollViewClass == "CmuxNextInputTests.ScrollViewAuditTests.WheelScrollView")
    }

    @Test func aScrollViewThatOverridesScrollWheelAndOptsBackInIsResponsive() throws {
        let optIn = Self.scrollView(OptInWheelScrollView(frame: NSRect(x: 0, y: 0, width: 100, height: 100)), document: NSView())
        let audit = DebugInputScrollViews(auditing: [Self.root(optIn)])
        let row = try #require(audit.rows.first)
        #expect(row.scrollWheelOverrides == ["scroll_view"])
        #expect(row.scrollViewCompatible == true)
        #expect(row.responsive == true)
        #expect(audit.notResponsive == 0)
    }

    @Test func aDrawingDocumentIsResponsiveOnlyWhenItsClassSaysCompatible() {
        let drawing = Self.scrollView(document: DrawingDocument())
        let compatible = Self.scrollView(document: CompatibleDrawingDocument())
        let nonDrawing = Self.scrollView(document: IncompatibleNonDrawingDocument())
        let audit = DebugInputScrollViews(auditing: [Self.root(drawing, compatible, nonDrawing)])
        #expect(audit.rows.map(\.documentViewOverridesDraw) == [true, true, false])
        #expect(audit.rows.map(\.documentViewCompatible) == [false, true, false])
        #expect(audit.rows.map(\.responsive) == [false, true, true], "an incompatible document view counts only when it draws")
        #expect(audit.notResponsive == 1)
    }

    @Test func nestedScrollViewsAreListedInDepthFirstOrderAcrossWindows() {
        let inner = Self.scrollView(document: NSView())
        let outerDocument = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        outerDocument.addSubview(inner)
        let outer = Self.scrollView(document: outerDocument)
        let other = Self.scrollView(document: nil)
        let audit = DebugInputScrollViews(auditing: [Self.root(outer, number: 1), Self.root(other, number: 2)])
        #expect(audit.rows.map(\.window) == [1, 1, 2])
        #expect(audit.rows[2].documentViewClass == nil)
        #expect(audit.rows[2].documentViewCompatible == nil)
        #expect(audit.rows[2].responsive)
    }

    @Test func aScrollViewInsideAHostingViewIsSwiftUIHosted() throws {
        let hosting = NSHostingView(rootView: EmptyView())
        let scrollView = Self.scrollView(document: NSView())
        hosting.addSubview(scrollView)
        let rows = DebugInputScrollViews(auditing: [Self.root(hosting, Self.scrollView(document: NSView()))]).rows
        #expect(rows.map(\.swiftUIHosted) == [true, false])
        #expect(DebugInputScrollViews.className(type(of: hosting)) == "SwiftUI.NSHostingView", "generic arguments left out")
    }

    @Test func classNamesAreTheSameOnEveryLaunch() throws {
        let row = try #require(DebugInputScrollViews(auditing: [Self.root(Self.scrollView(document: PrivateDocument()))]).rows.first)
        #expect(row.documentViewClass == "CmuxNextInputTests.PrivateDocument")
        #expect(row.documentViewClass?.contains("$") == false)
        #expect(DebugInputScrollViews.stableName("Module.(unknown context at $10a3c4f2c).Name") == "Module.Name")
        #expect(DebugInputScrollViews.stableName("SwiftUI.Foo<X>.Bar") == "SwiftUI.Foo.Bar", "a nested type after the generic arguments stays")
        #expect(DebugInputScrollViews.stableName("A.B<C<D>, (E) -> F>.G<H>") == "A.B.G")
        #expect(DebugInputScrollViews.stableName("A.B<M.(unknown context at $1).P>.(unknown context at $2).Q") == "A.B.Q")
    }

    @Test func theAuditWalksAWindowsFrameView() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let contentView = try #require(window.contentView)
        let frameView = try #require(contentView.superview, "a titled window's content view sits in its frame view")
        contentView.addSubview(Self.scrollView(document: NSView()))
        frameView.addSubview(Self.scrollView(FrameScrollView(frame: NSRect(x: 0, y: 0, width: 100, height: 20)), document: NSView()))
        let rows = DebugInputScrollViews(auditing: [window]).rows
        #expect(rows.map(\.scrollViewClass).sorted() == ["CmuxNextInputTests.ScrollViewAuditTests.FrameScrollView", "NSScrollView"],
                "a scroll view outside the content view (a title bar accessory's place) is found too")
        let row = try #require(rows.first)
        #expect(row.window == window.windowNumber)
        #expect(row.windowClass == "NSWindow")
        #expect(row.windowVisible == false)
    }

    @Test func theSchemaIsStable() throws {
        let audit = DebugInputScrollViews(auditing: [Self.root(Self.scrollView(document: NSView()), Self.scrollView(document: nil))])
        let data = try JSONEncoder().encode(audit)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["rows", "not_responsive"])
        let rows = try #require(object["rows"] as? [[String: Any]])
        let base: Set<String> = ["window", "window_class", "window_visible", "scroll_view_class", "clip_view_class",
                                 "scroll_view_compatible", "scroll_wheel_overrides", "swiftui_hosted", "responsive"]
        #expect(Set(rows[0].keys) == base.union(["document_view_class", "document_view_compatible", "document_view_overrides_draw"]))
        #expect(Set(rows[1].keys) == base, "no document view: its keys are left out")
        #expect(try JSONDecoder().decode(DebugInputScrollViews.self, from: data) == audit)
    }

    @Test func theSourceReadsOnlyWhenAskedAndFillsTheSection() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(Self.scrollView(WheelScrollView(frame: NSRect(x: 0, y: 0, width: 100, height: 100)), document: NSView()))
        let audit = DebugInputScrollViews(auditing: [window])
        let reads = Reads()
        let debugInput = DebugInput(sources: [ScrollViewAuditSource { await reads.note(); return audit }])
        #expect(await reads.count == 0, "nothing walks before a request")

        let reply = try await debugInput.reply(to: DebugInput.Request(params: ["sections": .array([.string("scroll_views")])]))
        #expect(await reads.count == 1)
        #expect(reply["absent"] == .array([]))
        let value = try #require(reply["scroll_views"])
        let data = try JSONSerialization.data(withJSONObject: value.foundationObject)
        let section = try JSONDecoder().decode(DebugInputScrollViews.self, from: data)
        #expect(section == audit)
        #expect(section.rows.map(\.scrollWheelOverrides) == [["scroll_view"]])
        #expect(section.notResponsive == 1)

        let reset = try await debugInput.reply(to: DebugInput.Request(params: ["action": .string("reset")]))
        #expect(reset["reset"] == .array([.string("scroll_views")]))
        #expect(await reads.count == 1, "reset walks nothing")
    }

    actor Reads {
        private(set) var count = 0
        func note() { count += 1 }
    }
}
