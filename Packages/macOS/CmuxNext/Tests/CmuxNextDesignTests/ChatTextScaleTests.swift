@testable import CmuxNextDesign
import CoreGraphics
import Foundation
import Testing

/// The agent chat and the Chief chat draw at Default's size at Compact (user 2026-11-16: "make it so
/// compact and default density have same size of both imessage and chat trajectory"). The host writes the
/// chat's text scale beside the density's (`--cmux-chat-text-scale`); each case reads it from the script the
/// app runs in the chat's page, as the page does.
@MainActor @Suite(.serialized) struct ChatTextScaleTests {
    private func chatTextScale(_ preset: DensityPreset) -> Double? {
        let design = DesignSettings.shared
        let saved = design.densityTokens
        defer { design.densityTokens = saved }
        design.densityTokens = preset.tokens
        let script = design.interfaceScaleScript()
        guard let range = script.range(of: #"setProperty\('--cmux-chat-text-scale', '([0-9.]+)'\)"#, options: .regularExpression)
        else { return nil }
        let match = String(script[range])
        return Double(match.split(separator: "'")[3])
    }

    @Test(arguments: [DensityPreset.ultraCompact, .compact])
    func belowDefaultTheChatKeepsDefaultsSize(preset: DensityPreset) throws {
        let atDefault = try #require(chatTextScale(.cozy), "the host writes --cmux-chat-text-scale")
        let here = try #require(chatTextScale(preset), "\(preset): the host writes --cmux-chat-text-scale")
        #expect(abs(here - atDefault) < 0.0001, "\(preset): chat text scale \(here), Default's \(atDefault)")
    }

    @Test(arguments: [DensityPreset.comfortable, .spacious])
    func aboveDefaultTheChatGrowsWithThePage(preset: DensityPreset) throws {
        let design = DesignSettings.shared
        let saved = design.densityTokens
        defer { design.densityTokens = saved }
        design.densityTokens = preset.tokens
        let page = Double(Typography.pageScale)
        let here = try #require(chatTextScale(preset))
        #expect(abs(here - page) < 0.0001, "\(preset): chat text scale \(here), the page's \(page)")
    }
}
