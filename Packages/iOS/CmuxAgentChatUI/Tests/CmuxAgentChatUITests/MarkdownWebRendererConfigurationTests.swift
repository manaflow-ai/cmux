import Foundation
import SwiftUI
import Testing

@testable import CmuxAgentChatUI

@Suite("Markdown web renderer configuration")
struct MarkdownWebRendererConfigurationTests {
#if canImport(UIKit)
    @Test("page zoom tracks the Dynamic Type body size with 1.0 at .large")
    func pageZoomMapping() {
        #expect(ChatArtifactMarkdownView.pageZoom(for: .large) == 1)
        #expect(ChatArtifactMarkdownView.pageZoom(for: .xSmall) < 1)
        #expect(ChatArtifactMarkdownView.pageZoom(for: .accessibility5) > 3)

        let ordered: [DynamicTypeSize] = [
            .xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge,
            .accessibility1, .accessibility2, .accessibility3, .accessibility4, .accessibility5,
        ]
        let zooms = ordered.map { ChatArtifactMarkdownView.pageZoom(for: $0) }
        #expect(zooms == zooms.sorted())
    }

    @Test("theme resolves parity CSS variables for both appearances")
    @MainActor
    func themeResolution() {
        let light = MarkdownWebTheme.resolve(isDark: false)
        let dark = MarkdownWebTheme.resolve(isDark: true)

        #expect(!light.isDark)
        #expect(dark.isDark)
        #expect(light.background == "transparent")
        #expect(dark.background == "transparent")
        for value in [light.mutedBackground, light.border, dark.mutedBackground, dark.border] {
            #expect(value.hasPrefix("rgba("))
        }
        #expect(light != dark)
    }

    @Test("missing bundle assets disable the web renderer instead of crashing")
    @MainActor
    func missingAssetsFallBack() async throws {
        let emptyBundleDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-markdown-assets-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyBundleDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: emptyBundleDir) }

        let bundle = try #require(Bundle(url: emptyBundleDir))
        let assets = MarkdownWebViewerAssets(bundle: bundle)
        #expect(!assets.isAvailable)
        #expect(!assets.isUsable)
        #expect(assets.shellHTML() == nil)
        #expect(assets.asset(name: "mermaid.min", ext: "js") == nil)
        #expect(await assets.assets([(name: "mermaid.min", ext: "js")]) == nil)
    }
#endif
}
