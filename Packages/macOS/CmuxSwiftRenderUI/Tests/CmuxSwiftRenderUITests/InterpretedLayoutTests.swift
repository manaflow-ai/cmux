import AppKit
import CmuxSwiftRender
import SwiftUI
import Testing
@testable import CmuxSwiftRenderUI

@MainActor
@Suite("Interpreted sidebar layout", .serialized)
struct InterpretedLayoutTests {
    @Test func fixedFrameHonorsAlignment() throws {
        let source = "Rectangle().fill(.red).frame(width: 20, height: 12).frame(width: 100, height: 80, alignment: .topTrailing)"
        let native = Rectangle().fill(.red).frame(width: 20, height: 12)
            .frame(width: 100, height: 80, alignment: .topTrailing)
        try expectSameRedBounds(source, native: native)
    }

    @Test func horizontalStacksHonorTopAlignment() throws {
        let children = "Rectangle().fill(.red).frame(width: 20, height: 12); Rectangle().fill(.blue).frame(width: 30, height: 60)"
        try expectSameRedBounds("HStack(alignment: .top, spacing: 0) { \(children) }", native:
            HStack(alignment: .top, spacing: 0) {
                Rectangle().fill(.red).frame(width: 20, height: 12)
                Rectangle().fill(.blue).frame(width: 30, height: 60)
            })
        try expectSameRedBounds("LazyHStack(alignment: .top, spacing: 0) { \(children) }", native:
            LazyHStack(alignment: .top, spacing: 0) {
                Rectangle().fill(.red).frame(width: 20, height: 12)
                Rectangle().fill(.blue).frame(width: 30, height: 60)
            })
    }

    @Test func verticalAndOverlayStacksHonorAlignment() throws {
        let children = "Rectangle().fill(.red).frame(width: 20, height: 12); Rectangle().fill(.blue).frame(width: 60, height: 30)"
        try expectSameRedBounds("VStack(alignment: .trailing, spacing: 0) { \(children) }", native:
            VStack(alignment: .trailing, spacing: 0) {
                Rectangle().fill(.red).frame(width: 20, height: 12)
                Rectangle().fill(.blue).frame(width: 60, height: 30)
            })
        try expectSameRedBounds("LazyVStack(alignment: .trailing, spacing: 0) { \(children) }", native:
            LazyVStack(alignment: .trailing, spacing: 0) {
                Rectangle().fill(.red).frame(width: 20, height: 12)
                Rectangle().fill(.blue).frame(width: 60, height: 30)
            })
        try expectSameRedBounds("ZStack(alignment: .bottomTrailing) { Rectangle().fill(.blue).frame(width: 60, height: 60); Rectangle().fill(.red).frame(width: 20, height: 12) }", native:
            ZStack(alignment: .bottomTrailing) {
                Rectangle().fill(.blue).frame(width: 60, height: 60)
                Rectangle().fill(.red).frame(width: 20, height: 12)
            })
    }

    @Test func maximumWidthMatchesNativeProposalClamping() throws {
        for width in [40.0, 240.0] {
            try expectSameRedBounds("Rectangle().fill(.red).frame(maxWidth: 100).frame(height: 12)", native:
                Rectangle().fill(.red).frame(maxWidth: 100).frame(height: 12), width: width)
        }
    }

    @Test func infinityHeightFillsSidebarViewport() throws {
        let source = """
        VStack(spacing: 0) {
            Rectangle().fill(.red).frame(width: 20, height: 12)
            Spacer()
            Rectangle().fill(.blue).frame(width: 20, height: 12)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        """
        let node = try #require(SwiftViewInterpreter().evaluate(source))
        let content = CustomSidebarContentView(
            state: .swiftSource(source), swiftRender: node, hasRenderedSwift: true,
            dispatch: .noop, contentInsets: .zero
        )
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: 240, height: 200)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let red = try #require(colorBounds(bitmap, red: true))
        let blue = try #require(colorBounds(bitmap, red: false))
        // Host padding reserves 8 points above and 16 below the authored view.
        #expect(abs(blue.minY - red.minY) >= CGFloat(bitmap.pixelsHigh) * 0.75)
    }

    private func expectSameRedBounds(_ source: String, native: some View, width: Double = 240) throws {
        let node = try #require(SwiftViewInterpreter().evaluate(source))
        let actual = try render(RenderNodeView(node: node), width: width)
        let expected = try render(native, width: width)
        let actualBounds = try #require(colorBounds(actual, red: true))
        let expectedBounds = try #require(colorBounds(expected, red: true))
        #expect(actualBounds == expectedBounds, "\(source)")
    }

    private func render(_ view: some View, width: Double) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view.frame(width: width, height: 100))
        renderer.scale = 1
        return NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
    }

    private func colorBounds(_ bitmap: NSBitmapImageRep, red: Bool) -> CGRect? {
        var result: CGRect?
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      color.alphaComponent > 0.9, color.greenComponent < 0.5,
                      red ? color.redComponent > 0.7 && color.blueComponent < 0.5
                          : color.blueComponent > 0.7 && color.redComponent < 0.5 else { continue }
                let pixel = CGRect(x: x, y: y, width: 1, height: 1)
                result = result.map { $0.union(pixel) } ?? pixel
            }
        }
        return result
    }
}
