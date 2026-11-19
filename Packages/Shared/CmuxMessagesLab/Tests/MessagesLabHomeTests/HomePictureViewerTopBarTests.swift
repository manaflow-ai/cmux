import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import MessagesLabHome

/// The picture viewer's top bar (the user, 2026-11-06, msg 23681: in the Before|After viewer the chat's round
/// compose button sat on the title, so "Dark · After" read "k · After"): the title, the Light | Dark switch,
/// the counter and the close button each keep their own space, and none of them goes under a button that the
/// pane floats over the viewer's top-left corner, at any width and title length.
@Suite(.serialized) @MainActor struct HomePictureViewerTopBarTests {
    static let short = "Dark · After"
    static let long = "Dark · After, the sidebar with the new rows and the collapsed workspace groups shown at full width"

    /// A Before|After × Light|Dark gallery whose pictures are named `title`, opened on its comparison.
    static func gallery(title: String) -> HomePictureGallery {
        var items: [HomePictureGallery.Item] = []
        for row in 0..<2 {
            for column in 0..<2 {
                let name = "r\(row)c\(column)"
                items.append(.init(source: name, url: URL(fileURLWithPath: "/tmp/\(name).png"), title: title, row: row, column: column))
            }
        }
        var gallery = HomePictureGallery(items: items, index: 3)
        gallery.rowLabels = [0: "Light", 1: "Dark"]
        gallery.opensComparing = true
        return gallery
    }

    /// The viewer over a chat column of `width`, with the column's round compose button (38 points, 12 from the
    /// left, centred 26 from the top, as `HomeChatColumnView` places it) drawn above it when `compose` is on.
    static func open(width: CGFloat, title: String, compose: Bool) async throws -> (HomePictureViewer, CGRect?) {
        let host = NSView(frame: CGRect(x: 0, y: 0, width: width, height: 700))
        let picture = try HomePictureViewerTests.image(width: 400, height: 250)
        let viewer = HomePictureViewer(frame: host.bounds, gallery: gallery(title: title), load: { _ in picture })
        viewer.reduceMotion = { true }
        host.addSubview(viewer)
        var button: CGRect?
        if compose {
            let side: CGFloat = 38
            let round = NSButton(frame: CGRect(x: 12, y: host.bounds.height - 26 - side / 2, width: side, height: side))
            host.addSubview(round)
            button = viewer.convert(round.bounds, from: round)
        }
        await viewer.loaded()
        viewer.needsLayout = true
        viewer.layoutSubtreeIfNeeded()
        return (viewer, button)
    }

    /// The top bar's visible pieces, in the viewer's coordinates: the title, the row switch, the counter and
    /// the close button (the full-size backdrop, picture and slider and the side buttons are not in the bar).
    static func barFrames(_ viewer: HomePictureViewer) -> [(String, CGRect)] {
        viewer.subviews.compactMap { view -> (String, CGRect)? in
            guard !view.isHidden, view.frame.width > 0, view.frame.height > 0, view.frame.minY < 44,
                  view.frame.width < viewer.bounds.width * 0.9 else { return nil }
            if let label = view as? NSTextField {
                guard !label.stringValue.isEmpty else { return nil }
                return ("label \(label.stringValue.prefix(12))", view.frame)
            }
            return ("\(type(of: view))", view.frame)
        }
    }

    /// Whether `label` shows its whole text: its frame holds the text and the label cell's 2-point side insets
    /// (the capture of the fix showed "Ligh…After" and "2…4" with the text's bare width).
    static func whole(_ label: NSTextField) -> Bool {
        label.frame.width >= ceil(label.attributedStringValue.size().width) + 4
    }

    @Test func theComposeButtonAboveTheViewerLeavesTheTitleWhole() async throws {
        let (viewer, button) = try await Self.open(width: 620, title: Self.short, compose: true)
        let compose = try #require(button)
        let labels = viewer.subviews.compactMap { $0 as? NSTextField }
        let title = try #require(labels.first { $0.stringValue == Self.short })
        #expect(!title.frame.intersects(compose), "title \(title.frame) under the compose button \(compose)")
        #expect(Self.whole(title), "title \(title.frame) cut short")
        let counter = try #require(labels.first { $0.stringValue.contains("4") && $0.stringValue != Self.short })
        #expect(Self.whole(counter), "counter \(counter.stringValue) \(counter.frame) cut short")
    }

    @Test(arguments: [320, 620, 1200] as [CGFloat], [short, long, ""])
    func theTopBarPiecesNeverOverlap(width: CGFloat, title: String) async throws {
        for compose in [false, true] {
            let (viewer, button) = try await Self.open(width: width, title: title, compose: compose)
            let frames = Self.barFrames(viewer)
            #expect(frames.contains { $0.0 == "NSSegmentedControl" }, "the Light | Dark switch shows")
            for (i, a) in frames.enumerated() {
                for b in frames.dropFirst(i + 1) {
                    #expect(!a.1.intersects(b.1), "\(a.0) \(a.1) overlaps \(b.0) \(b.1) at width \(width)")
                }
                if let button { #expect(!a.1.intersects(button), "\(a.0) \(a.1) under the compose button at width \(width)") }
                #expect(a.1.minX >= 0 && a.1.maxX <= viewer.bounds.width, "\(a.0) \(a.1) leaves the viewer at width \(width)")
            }
        }
    }
}
