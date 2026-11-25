@testable import CmuxNextDesign
import CoreGraphics
import Foundation
import Testing

/// The agent chat and the Chief chat draw at Default's size at every density (user 2026-11-16: "make it so
/// compact and default density have same size of both imessage and chat trajectory"; 2026-11-19: the same at
/// spacious too). The host writes the
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

    /// The chat trajectory's text is one size at every density (user 2026-11-19: "chat trajectory size should be
    /// same at normal and compact and spacious densities"): a roomier density spaces the chat out, never grows its
    /// text. Text Size still does (below).
    @Test(arguments: [DensityPreset.comfortable, .spacious])
    func aboveDefaultTheChatKeepsDefaultsSizeToo(preset: DensityPreset) throws {
        let atDefault = try #require(chatTextScale(.cozy))
        let here = try #require(chatTextScale(preset))
        #expect(abs(here - atDefault) < 0.0001, "\(preset): chat text scale \(here), Default's \(atDefault)")
    }

    /// A chrome font size set in Settings (Text Size) still sizes the chat, the same at every density.
    @Test(arguments: DensityPreset.allCases)
    func aSetTextSizeSizesTheChatAtEveryDensity(preset: DensityPreset) throws {
        let design = DesignSettings.shared
        let saved = design.overrides[.chromeFontSize]
        defer { design.setOverride(.chromeFontSize, saved) }
        design.setOverride(.chromeFontSize, 15.6)
        let atDefault = try #require(chatTextScale(.cozy))
        let here = try #require(chatTextScale(preset))
        #expect(atDefault > 1.1, "Text Size grows the chat")
        #expect(abs(here - atDefault) < 0.0001, "\(preset): chat text scale \(here), Default's \(atDefault)")
    }

    /// The Chief chat's native transcript draws at ``Typography/chatUserScale``: with a chrome font size set it is
    /// that size over Default's at every density, as it is at Default.
    @Test(arguments: DensityPreset.allCases)
    func theChiefChatsScaleIgnoresTheDensity(preset: DensityPreset) {
        let design = DesignSettings.shared
        let saved = (design.densityTokens, design.overrides[.chromeFontSize])
        defer { design.densityTokens = saved.0; design.setOverride(.chromeFontSize, saved.1) }
        design.setOverride(.chromeFontSize, 14)
        design.densityTokens = DensityPreset.cozy.tokens
        let atDefault = Typography.chatUserScale
        design.densityTokens = preset.tokens
        #expect(abs(Typography.chatUserScale - atDefault) < 0.0001, "\(preset): \(Typography.chatUserScale), Default's \(atDefault)")
    }
}
