import AppKit
@testable import CmuxNextDesign
import CoreGraphics
import Foundation
import Testing

/// Lawrence, msg 3790: "everywhere we say sign in, we need to have a button for signing in". The one
/// Sign In button every such place shows takes its size from the density tokens, so it sits with the
/// controls around it at every density, and a click runs the sign-in that place passes.
@Suite @MainActor struct SignInButtonTests {
    @Test func compactIsAControlsSize() {
        #expect(SignInButtonMetrics(density: DensityPreset.compact.tokens)
            == SignInButtonMetrics(height: 24, paddingX: 10, cornerRadius: 6, textSize: 12))
    }

    @Test func comfortableIsAComfortableControlsSize() {
        #expect(SignInButtonMetrics(density: DensityPreset.comfortable.tokens)
            == SignInButtonMetrics(height: 30, paddingX: 10, cornerRadius: 7, textSize: 13))
    }

    @Test func denserAndRoomierDensitiesFollow() {
        let ultra = SignInButtonMetrics(density: DensityPreset.ultraCompact.tokens)
        let spacious = SignInButtonMetrics(density: DensityPreset.spacious.tokens)
        #expect(ultra == SignInButtonMetrics(height: 21, paddingX: 8, cornerRadius: 6, textSize: 11.5))
        #expect(spacious == SignInButtonMetrics(height: 35, paddingX: 13, cornerRadius: 8, textSize: 14))
    }

    /// A custom density's exact control height (`tokens["controlHeight"]`) sizes the button too.
    @Test func exactControlHeightWins() {
        let custom = DensityTokens(id: "tight", name: "Tight", tokens: ["controlHeight": 22])
        #expect(SignInButtonMetrics(density: custom).height == 22)
    }

    @Test func buttonTakesItsDensitysHeight() {
        for preset in [DensityPreset.compact, .comfortable] {
            let button = SignInButton {}
            button.density = preset.tokens
            #expect(button.intrinsicContentSize.height == SignInButtonMetrics(density: preset.tokens, scale: Metrics.scale(1)).height)
            #expect(button.intrinsicContentSize.width > button.metrics.paddingX * 2)
        }
    }

    @Test func clickRunsTheSignIn() {
        var signedIn = 0
        let button = SignInButton { signedIn += 1 }
        button.performClick(nil)
        #expect(signedIn == 1)
        #expect(button.identifier == SignInButton.identifier)
        #expect(button.accessibilityLabel() == SignInButton.defaultTitle)
    }

    @Test func titleNamesWhatItSignsInTo() {
        let button = SignInButton(title: "Sign In to Claude") {}
        #expect(button.attributedTitle.string == "Sign In to Claude")
        button.retitle("Sign In")
        #expect(button.accessibilityLabel() == "Sign In")
    }

    /// The title reads on the fill in light and dark (the dialog default button's 4.5:1).
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func titleReadsOnItsFill(_ name: NSAppearance.Name) throws {
        let button = SignInButton {}
        button.appearance = try #require(NSAppearance(named: name))
        let look = button.look
        for surface in look.surfaces {
            #expect(look.title.contrast(with: surface) >= CmuxDialogButtonLook.minimumContrast)
        }
    }

    /// Renders the button at Compact and Comfortable, light and dark, to one PNG for review
    /// (`$CMUX_SIGNIN_SHOTS/sign-in-button.png`, else `.build/artifacts/`).
    @Test func rendersAtEachDensityLightAndDark() throws {
        let canvas = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 120))
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = NSColor.gray.cgColor
        for (row, preset) in [DensityPreset.compact, .comfortable].enumerated() {
            for (column, name) in [NSAppearance.Name.aqua, .darkAqua].enumerated() {
                let tile = NSView(frame: NSRect(x: 12 + CGFloat(column) * 174, y: 12 + CGFloat(row) * 54, width: 162, height: 46))
                tile.wantsLayer = true
                tile.appearance = NSAppearance(named: name)
                tile.layer?.backgroundColor = (name == .aqua ? NSColor.white : NSColor(white: 0.12, alpha: 1)).cgColor
                let button = SignInButton {}
                button.density = preset.tokens
                button.translatesAutoresizingMaskIntoConstraints = true
                let size = button.intrinsicContentSize
                button.frame = NSRect(x: (162 - size.width) / 2, y: (46 - size.height) / 2, width: size.width, height: size.height)
                tile.addSubview(button)
                canvas.addSubview(tile)
            }
        }
        canvas.layoutSubtreeIfNeeded()
        let rep = try #require(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
        canvas.cacheDisplay(in: canvas.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        let dir = ProcessInfo.processInfo.environment["CMUX_SIGNIN_SHOTS"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../../.build/artifacts").standardized
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try png.write(to: dir.appendingPathComponent("sign-in-button.png"))
    }
}
