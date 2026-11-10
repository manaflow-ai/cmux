import AppKit
@testable import CmuxHomeCore
import CmuxHomeRender
import CmuxNextDesign
@testable import CmuxNextHome
@testable import CmuxNextHomeModel
import CmuxNextTestSupport
import Foundation
@testable import MessagesLabHome
import Testing

/// The user, 2026-10-31, on Home over the Great Wave: "why is sidebar different color", "color of the
/// middle part looks bad too" and "chief sidebar bg and chief header bg needs to be same as rest of
/// the bgs". The conversation list laid a 35% scrim of its own and the chat's header a glass band at
/// rest, so the workspace sidebar, the list, the header and the chat read as different tints, in dark,
/// light and over a picture. Home has one veil: every column paints what the chat paints over the
/// window's tint, and the header shows no band while no message is under it.
@MainActor @Suite(.serialized, .closesItsWindows) struct HomeOneVeilTests {
    /// The default header band (the background tint) is the chat's own colour at the chat's own
    /// alpha: over a see-through window or a background image (a clear chat fill) it draws nothing,
    /// where it drew the colour at full opacity, a flat grey bar over the picture.
    @Test(arguments: [0.0, 0.4, 1.0])
    func theHeaderBandIsTheChatsColorAtTheChatsAlpha(_ alpha: Double) throws {
        let band = HomeTopFadeView(style: .backgroundTint)
        let chat = NSColor(srgbRed: 0.12, green: 0.12, blue: 0.12, alpha: alpha)
        band.applyColors(background: chat, light: false)
        let colors = try #require(band.gradient.colors as? [CGColor])
        #expect(!colors.isEmpty)
        for color in colors {
            let c = Self.rgba(color)
            #expect(c[3] <= alpha + 0.001, "the band draws alpha \(c[3]) over a chat of alpha \(alpha)")
            if c[3] > 0.001 { #expect(abs(c[0] - 0.12) < 0.002, "the band is not the chat's colour: \(c)") }
        }
    }

    private static func rgba(_ color: CGColor?) -> [Double] {
        guard let color, let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let c = color.converted(to: srgb, intent: .defaultIntent, options: nil)?.components, c.count >= 4 else { return [0, 0, 0, 0] }
        return c.prefix(4).map(Double.init)
    }
}
