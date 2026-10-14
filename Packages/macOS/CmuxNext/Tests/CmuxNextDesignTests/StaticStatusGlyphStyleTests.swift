import CoreGraphics
@testable import CmuxNextDesign
import Testing

/// hq#1957 status glyph thunderdome: the static status glyphs come in competing styles (the default
/// `still` from #20410, the quiet `dots`, the bold `pictograms`). Each style draws the six states apart
/// by shape alone at 10 pt, crisp at 1x (the pixel art) and on whole pixels at 2x, never animated and in
/// the state's own theme role, and the status icon switch selects each one.
@Suite struct StaticStatusGlyphStyleTests {
    /// The glyph's coverage at `pixels` square, 0...255 per pixel, row by row from the top.
    private func alpha(_ glyph: StaticStatusGlyph, _ style: StaticStatusGlyph.Style, pixels: Int) throws -> [UInt8] {
        let context = try #require(CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: pixels,
                                             space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue))
        context.setFillColor(gray: 0, alpha: 1)
        context.addPath(glyph.path(in: CGRect(x: 0, y: 0, width: pixels, height: pixels), style: style))
        context.fillPath(using: .evenOdd)
        let data = try #require(context.data)
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: pixels * pixels))
    }

    @Test(arguments: StaticStatusGlyph.Style.allCases)
    func eachStyleDrawsTheSixStatesApartByShape(_ style: StaticStatusGlyph.Style) throws {
        #expect(StaticStatusGlyph.allCases.map(\.rawValue) == ["idle", "working", "waiting", "permission", "done", "error"])
        for (pixels, least) in [(10, 12), (20, 30)] {
            let drawn = try StaticStatusGlyph.allCases.map { try alpha($0, style, pixels: pixels) }
            for (glyph, art) in zip(StaticStatusGlyph.allCases, drawn) {
                let ink = art.filter { $0 > 20 }
                #expect(ink.count >= pixels * pixels / 8, "\(style) \(glyph) @\(pixels): \(ink.count) inked pixels")
                if pixels == 10 {
                    // The 1x pixel art: every edge on a pixel, so nothing is partly covered.
                    #expect(ink.allSatisfy { $0 > 235 }, "\(style) \(glyph) has soft pixels at 1x")
                }
            }
            for i in drawn.indices {
                for j in drawn.indices where j > i {
                    let differ = zip(drawn[i], drawn[j]).filter { ($0 > 127) != ($1 > 127) }.count
                    #expect(differ >= least, "\(style): \(StaticStatusGlyph.allCases[i]) and \(StaticStatusGlyph.allCases[j]) differ in \(differ) pixels at \(pixels)")
                }
            }
        }
    }

    @Test(arguments: StaticStatusGlyph.Style.allCases)
    func eachStyleStaysInsideItsSquare(_ style: StaticStatusGlyph.Style) {
        for glyph in StaticStatusGlyph.allCases {
            for side in [10.0, 20, 30] {
                let rect = CGRect(x: 3, y: 5, width: side, height: side)
                let bounds = glyph.path(in: rect, style: style).boundingBoxOfPath
                #expect(!bounds.isEmpty && rect.insetBy(dx: -0.01, dy: -0.01).contains(bounds), "\(style) \(glyph) at \(side): \(bounds)")
            }
        }
    }

    @Test func theStylesDrawDifferentShapes() throws {
        for glyph in StaticStatusGlyph.allCases {
            let drawn = try StaticStatusGlyph.Style.allCases.map { try alpha(glyph, $0, pixels: 20) }
            #expect(Set(drawn).count == drawn.count, "\(glyph) is the same in two styles")
        }
    }

    @Test func theStatusIconSwitchSelectsEachStyleStillAndInItsThemeRole() {
        let sets: [(StatusIconSet, StaticStatusGlyph.Style)] = [(.still, .still), (.stillDots, .dots), (.stillPictograms, .pictograms)]
        #expect(StaticStatusGlyph.Style.allCases == sets.map(\.1))
        #expect(StatusIconSet.tunable.defaultValue == .symbols)
        let states: [StatusIndicatorState] = [.working(progress: nil), .waiting(kind: nil), .waiting(kind: .question),
                                              .waiting(kind: .permission), .waiting(kind: .auth), .success, .error]
        for (set, style) in sets {
            #expect(set.staticStyle == style)
            #expect(!set.tunableTitle.isEmpty)
            for state in states {
                let plan = StatusIndicatorPlan.make(state, style: .arc, animates: true, set: set)
                let glyph = StaticStatusGlyph(state)
                #expect(plan.glyph == .mark(.vector(glyph!, style)), "\(set) \(state)")
                #expect(plan.animation == nil && plan.tint == glyph!.tint, "\(set) \(state)")
            }
            // Idle draws nothing and known progress keeps its ring, as in the default set.
            #expect(StatusIndicatorPlan.make(.idle, style: .arc, animates: true, set: set) == .hidden)
            #expect(StatusIndicatorPlan.make(.working(progress: 0.5), style: .arc, animates: true, set: set).glyph == .ring(progress: 0.5))
        }
        #expect(StatusIconSet.symbols.staticStyle == nil)
    }
}
