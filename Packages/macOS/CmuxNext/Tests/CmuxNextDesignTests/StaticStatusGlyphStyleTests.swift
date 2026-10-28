import CoreGraphics
@testable import CmuxNextDesign
import Testing
import CmuxNextDesignTokens

/// hq#1957 status glyph thunderdome: the static status glyphs come in competing sets (the default
/// Static set from #20410, the quiet Dots, the bold Pictograms). Each set draws the six states apart
/// by shape alone at 10 pt, crisp at 1x (the pixel art), never animated and in the Static set's theme
/// role per state, and the Debug status icon switch selects each one without changing the default.
@Suite struct StaticStatusGlyphStyleTests {
    private static let staticGlyphs: [StaticStatusGlyph] = [.idle, .working, .waiting, .permission, .done, .error]

    /// Each static set: its switch value and its glyph per Static state.
    private static let sets: [(StatusIconSet, @Sendable (StaticStatusGlyph) -> StaticStatusGlyph)] = [
        (.still, { $0 }), (.stillDots, { $0.dots }), (.stillPictograms, { $0.pictograms }),
    ]

    /// The glyph's coverage at `pixels` square, 0...255 per pixel, row by row from the top.
    private func alpha(_ glyph: StaticStatusGlyph, pixels: Int) throws -> [UInt8] {
        let context = try #require(CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: pixels,
                                             space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue))
        context.setFillColor(gray: 0, alpha: 1)
        context.addPath(glyph.path(in: CGRect(x: 0, y: 0, width: pixels, height: pixels)))
        context.fillPath(using: .evenOdd)
        let data = try #require(context.data)
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: pixels * pixels))
    }

    @Test(arguments: [StatusIconSet.still, .stillDots, .stillPictograms])
    func eachSetDrawsTheSixStatesApartByShape(_ set: StatusIconSet) throws {
        let pick = try #require(Self.sets.first { $0.0 == set }?.1)
        let glyphs = Self.staticGlyphs.map(pick)
        #expect(Set(glyphs).count == glyphs.count, "\(set) repeats a glyph")
        for (pixels, least) in [(10, 12), (20, 30)] {
            let drawn = try glyphs.map { try alpha($0, pixels: pixels) }
            for (glyph, art) in zip(glyphs, drawn) {
                let ink = art.filter { $0 > 20 }
                #expect(ink.count >= pixels * pixels / 8, "\(glyph) @\(pixels): \(ink.count) inked pixels")
                if pixels == 10 {
                    // The 1x pixel art: every edge on a pixel, so nothing is partly covered.
                    #expect(ink.allSatisfy { $0 > 235 }, "\(glyph) has soft pixels at 1x")
                }
            }
            for i in drawn.indices {
                for j in drawn.indices where j > i {
                    let differ = zip(drawn[i], drawn[j]).filter { ($0 > 127) != ($1 > 127) }.count
                    #expect(differ >= least, "\(glyphs[i]) and \(glyphs[j]) differ in \(differ) pixels at \(pixels)")
                }
            }
        }
    }

    @Test func everySetGlyphStaysInsideItsSquare() {
        for glyph in Self.sets.flatMap({ set in Self.staticGlyphs.map(set.1) }) {
            for side in [10.0, 20, 30] {
                let rect = CGRect(x: 3, y: 5, width: side, height: side)
                let bounds = glyph.path(in: rect).boundingBoxOfPath
                #expect(!bounds.isEmpty && rect.insetBy(dx: -0.01, dy: -0.01).contains(bounds), "\(glyph) at \(side): \(bounds)")
            }
        }
    }

    @Test func theSetsDrawDifferentShapesInTheSameThemeRole() throws {
        for glyph in Self.staticGlyphs {
            let picks = Self.sets.map { $0.1(glyph) }
            let drawn = try picks.map { try alpha($0, pixels: 20) }
            #expect(Set(drawn).count == drawn.count, "\(glyph) is the same in two sets")
            #expect(Set(picks.map(\.tint)) == [glyph.tint], "\(glyph) changes its theme role across sets")
        }
    }

    @Test func theDebugSwitchSelectsEachSetStillAndTheDefaultStaysCodex() throws {
        #expect(StatusIconSet.tunable.defaultValue == .codex)
        let states: [StatusIndicatorState] = [.working(progress: nil), .waiting(kind: nil), .waiting(kind: .question),
                                              .waiting(kind: .permission), .waiting(kind: .auth), .success, .error]
        for (set, pick) in Self.sets {
            #expect(set.isStatic && !set.tunableTitle.isEmpty)
            for state in states {
                let glyph = pick(try #require(StaticStatusGlyph(state)))
                for animates in [true, false] {
                    let plan = StatusIndicatorPlan.make(state, style: .arc, animates: animates, set: set)
                    #expect(plan == StatusIndicatorPlan(glyph: .mark(.vector(glyph)), animation: nil, tint: glyph.tint), "\(set) \(state)")
                }
            }
            // Idle draws nothing and known progress keeps its ring, as in the Static set.
            #expect(StatusIndicatorPlan.make(.idle, style: .arc, animates: true, set: set) == .hidden)
            #expect(StatusIndicatorPlan.make(.working(progress: 0.5), style: .arc, animates: true, set: set).glyph == .ring(progress: 0.5))
        }
        #expect(!StatusIconSet.codex.isStatic && StatusIconSet.codex.staticGlyph(for: .success) == nil)
    }
}
