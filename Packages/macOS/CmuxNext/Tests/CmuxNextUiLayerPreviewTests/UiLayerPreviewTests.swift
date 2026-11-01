// The preview leaf is Debug-only (CMUX_UI_LAYER_PREVIEW); in Release this
// target builds with no tests.
#if CMUX_UI_LAYER_PREVIEW
import Testing
@testable import CmuxNextUiLayerPreview

@Suite struct UiLayerPreviewTests {
    @Test func sampleDataKeepsProjectionFields() {
        let data = UiLayerPreviewData(
            workspaceName: "Demo",
            tabTitle: "Terminal",
            tabSubtitle: "Ready",
            composerPlaceholder: "Captured at 12:00"
        )

        #expect(data.workspaceName == "Demo")
        #expect(data.tabTitle == "Terminal")
        #expect(data.tabSubtitle == "Ready")
        #expect(data.composerPlaceholder == "Captured at 12:00")
    }
}
#endif
