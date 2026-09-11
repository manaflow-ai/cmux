import AppKit
import SwiftUI
import Testing
@testable import CmuxFoundation

@Suite("SwiftUI sidebar font rendering")
@MainActor
struct CmuxSwiftUIFontRenderingTests {
    @Test("Custom sidebar weights render distinct glyphs", arguments: ["Menlo", "Georgia"])
    func customWeightsRenderDistinctGlyphs(family: String) throws {
        let regular = CmuxFontResolver.swiftUIFont(family: family, size: 24, weight: .regular)
        let semibold = CmuxFontResolver.swiftUIFont(family: family, size: 24, weight: .semibold)

        #expect(try pixels(regular) != pixels(semibold))
    }

    @Test("Custom sidebar bold matches the installed bold face", arguments: ["Menlo", "Georgia"])
    func boldUsesInstalledFace(family: String) throws {
        let resolved = CmuxFontResolver.swiftUIFont(family: family, size: 24, weight: .bold)
        let installed = CmuxFontResolver.appKitFont(family: family, size: 24, weight: .bold)
        let expected = Font.custom(installed.fontName, size: 24)

        #expect(try pixels(resolved) == pixels(expected))
    }

    private func pixels(_ font: Font) throws -> Data {
        let renderer = ImageRenderer(content:
            Text("Sidebar 123")
                .font(font)
                .foregroundStyle(.black)
                .frame(width: 240, height: 56, alignment: .leading)
                .background(.white)
        )
        let image = try #require(renderer.cgImage)
        let data = try #require(image.dataProvider?.data)
        return data as Data
    }
}
