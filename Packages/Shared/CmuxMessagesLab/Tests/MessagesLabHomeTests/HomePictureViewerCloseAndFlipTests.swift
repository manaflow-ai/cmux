import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import MessagesLabHome

/// The Before|After viewer (the user, 2026-11-07): "in gallery ui, i have to press esc twice to close it, ideally i
/// just press close once", and "dragging the thing around left/right to see before/after is not good either". One
/// Esc (or one click on Close) closes the viewer whatever has focus in it; a pair opens side by side, and a click
/// or Space flips one picture in place between Before and After (B and A pick one), the slider kept as a choice.
@Suite(.serialized) @MainActor struct HomePictureViewerCloseAndFlipTests {
    /// A 400 × 250 picture whose left half is `left` and right half is `right` (sRGB 0...1 components).
    static func halves(_ left: (CGFloat, CGFloat, CGFloat), _ right: (CGFloat, CGFloat, CGFloat)) throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try #require(CGContext(data: nil, width: 400, height: 250, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: left.0, green: left.1, blue: left.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 250))
        ctx.setFillColor(CGColor(srgbRed: right.0, green: right.1, blue: right.2, alpha: 1))
        ctx.fill(CGRect(x: 200, y: 0, width: 200, height: 250))
        return try #require(ctx.makeImage())
    }

    /// Before: red | green. After: yellow | blue. A sample names the half it shows.
    static let before = (red: (1.0, 0.0, 0.0) as (CGFloat, CGFloat, CGFloat), green: (0.0, 1.0, 0.0) as (CGFloat, CGFloat, CGFloat))
    static let after = (yellow: (1.0, 1.0, 0.0) as (CGFloat, CGFloat, CGFloat), blue: (0.0, 0.0, 1.0) as (CGFloat, CGFloat, CGFloat))

    /// The viewer, in a window, on a Before|After pair it opens comparing (as a table's pair opens).
    static func open() async throws -> (HomePictureViewer, NSWindow, () -> Int) {
        let pictures = [try halves(before.red, before.green), try halves(after.yellow, after.blue)]
        let items = ["Before", "After"].enumerated().map { i, title in
            HomePictureGallery.Item(source: "s\(i)", url: URL(fileURLWithPath: "/tmp/s\(i).png"), title: title, row: 0, column: i)
        }
        var gallery = HomePictureGallery(items: items, index: 0)
        gallery.opensComparing = true
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let viewer = HomePictureViewer(frame: CGRect(x: 0, y: 0, width: 1000, height: 700), gallery: gallery,
                                       load: { item in pictures[item.column] })
        viewer.reduceMotion = { true }
        var closed = 0
        viewer.onClose = { closed += 1 }
        window.contentView?.addSubview(viewer)
        window.makeFirstResponder(viewer)
        await viewer.loaded()
        viewer.layoutSubtreeIfNeeded()
        return (viewer, window, { closed })
    }

    static func key(_ characters: String, code: UInt16) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                      characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    static let escape: UInt16 = 53, space: UInt16 = 49

    static func compareView(_ viewer: HomePictureViewer) throws -> HomePictureCompare {
        try #require(viewer.subviews.compactMap { $0 as? HomePictureCompare }.first)
    }

    /// Which test colour the comparison shows at `fraction` of its width, half way down.
    static func colour(_ viewer: HomePictureViewer, at fraction: CGFloat) throws -> String {
        let view = try compareView(viewer)
        view.layoutSubtreeIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = try #require(rep.cgImage)
        let p = try HomePictureViewerTests.pixel(image, x: Int(CGFloat(image.width) * fraction), y: image.height / 2)
        switch (p.r > 160, p.g > 160, p.b > 160) {
        case (true, false, false): return "red"
        case (false, true, false): return "green"
        case (true, true, false): return "yellow"
        case (false, false, true): return "blue"
        default: return "other(\(p.r),\(p.g),\(p.b))"
        }
    }

    // MARK: Close

    @Test func oneEscapeClosesTheViewerOpenedOnItsComparison() async throws {
        let (viewer, window, closed) = try await Self.open()
        #expect(viewer.isComparing)
        window.firstResponder?.keyDown(with: try Self.key("\u{1b}", code: Self.escape))
        #expect(closed() == 1, "one Esc closes the viewer")
        #expect(viewer.isClosed)
        window.close()
    }

    @Test func oneEscapeClosesTheViewerWhateverControlInItHasFocus() async throws {
        let (viewer, window, closed) = try await Self.open()
        // A control of the viewer (its Light | Dark switch, the bar's tools) holds focus, as with Full Keyboard Access.
        let control = try #require(viewer.subviews.compactMap { $0 as? NSControl }.first { !$0.isHidden })
        control.keyDown(with: try Self.key("\u{1b}", code: Self.escape))
        #expect(closed() == 1, "one Esc from \(type(of: control)) closes the viewer")
        window.close()
    }

    @Test func oneClickOnCloseClosesTheViewer() async throws {
        let (viewer, window, closed) = try await Self.open()
        let close = try #require(viewer.subviews.compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == CmuxStrings.closePictureViewer })
        close.performClick(nil)
        #expect(closed() == 1)
        window.close()
    }

    // MARK: Side by side and flip

    @Test func aPairOpensSideBySideNotOnTheSlider() async throws {
        let (viewer, window, _) = try await Self.open()
        // Side by side, each picture whole: its right half (green, blue) shows at three quarters of each side.
        #expect(try Self.colour(viewer, at: 0.375) == "green", "Before is whole on the left, not cut by a slider")
        #expect(try Self.colour(viewer, at: 0.875) == "blue", "After is whole on the right")
        viewer.close()
        window.close()
    }

    @Test func spaceAndClickFlipOnePictureInPlaceAndBAndAPickOne() async throws {
        let (viewer, window, _) = try await Self.open()
        viewer.keyDown(with: try Self.key(" ", code: Self.space))
        #expect(try Self.colour(viewer, at: 0.25) == "red", "Space shows Before alone, large")
        #expect(try Self.colour(viewer, at: 0.75) == "green")
        viewer.keyDown(with: try Self.key(" ", code: Self.space))
        #expect(try Self.colour(viewer, at: 0.25) == "yellow", "Space again flips to After in the same place")
        #expect(try Self.colour(viewer, at: 0.75) == "blue")
        viewer.keyDown(with: try Self.key("b", code: 11))
        #expect(try Self.colour(viewer, at: 0.75) == "green", "B shows Before")
        viewer.keyDown(with: try Self.key("a", code: 0))
        #expect(try Self.colour(viewer, at: 0.75) == "blue", "A shows After")
        // A click on the picture flips it too.
        let compare = try Self.compareView(viewer)
        let middle = compare.convert(CGPoint(x: compare.bounds.midX, y: compare.bounds.midY), to: nil)
        let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: middle, modifierFlags: [], timestamp: 0,
                                                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        compare.mouseDown(with: click)
        #expect(try Self.colour(viewer, at: 0.75) == "green", "a click flips back to Before")
        viewer.close()
        window.close()
    }

    @Test func theSliderStaysAChoiceInTheBar() async throws {
        let (viewer, window, _) = try await Self.open()
        // The bar's compare styles: Side by Side, Flip, Slider.
        let bar = viewer.subviews.flatMap(\.subviews)
        let styles = try #require(bar.compactMap { $0 as? NSSegmentedControl }.first { $0.segmentCount == 3 && !$0.isHidden },
                                  "a three-way compare style control shows while comparing")
        #expect(styles.selectedSegment == 0, "side by side is the default")
        styles.selectedSegment = 2
        _ = styles.sendAction(styles.action, to: styles.target)
        #expect(try Self.colour(viewer, at: 0.375) == "red", "the slider shows Before left of its middle divider")
        #expect(try Self.colour(viewer, at: 0.625) == "blue", "and After right of it")
        viewer.close()
        window.close()
    }
}
