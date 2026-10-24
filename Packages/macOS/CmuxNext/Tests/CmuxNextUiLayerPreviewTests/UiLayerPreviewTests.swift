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
