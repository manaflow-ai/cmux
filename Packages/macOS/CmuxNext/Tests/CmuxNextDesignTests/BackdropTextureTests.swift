import AppKit
import Testing
@testable import CmuxNextDesign

@MainActor
struct BackdropTextureTests {
    @Test func defaultTextureUsesAQuietOrderedDither() {
        #expect(BackdropTexture.default.filter == .orderedDither4x4)
        #expect(BackdropTexture.default.strength == 0.12)
    }

    @Test(arguments: [BackdropTextureFilter.none, .orderedDither4x4, .orderedDither8x8, .halftone, .grain])
    func filtersAreRepresentedByStablePlans(_ filter: BackdropTextureFilter) {
        let texture = BackdropTexture(filter: filter, strength: 2)
        #expect(texture.filter == filter)
        #expect(texture.strength == 1)
        #expect(texture.id == "\(filter.rawValue):1.000")
    }

    @Test func invalidStrengthFallsBackToTheSafeRange() {
        #expect(BackdropTexture(filter: .grain, strength: -0.5).strength == 0)
        #expect(BackdropTexture(filter: .grain, strength: .infinity).strength == 1)
        #expect(BackdropTexture(filter: .grain, strength: .nan).strength == 0)
    }
}
