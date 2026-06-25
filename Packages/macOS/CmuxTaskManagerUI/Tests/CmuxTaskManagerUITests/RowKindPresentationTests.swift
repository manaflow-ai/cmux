import CmuxTaskManager
import Testing

@testable import CmuxTaskManagerUI

@Suite("Task Manager row-kind presentation")
struct RowKindPresentationTests {
    @Test("every kind maps to a non-empty SF Symbol name")
    func systemImageCoverage() {
        let kinds: [CmuxTaskManagerRow.Kind] = [
            .window, .workspace, .tag, .pane, .terminalSurface, .browserSurface,
            .webview, .process, .programAggregate, .codingAgentAggregate,
            .childMemoryAggregate,
        ]
        for kind in kinds {
            #expect(!kind.systemImage.isEmpty)
        }
    }

    @Test("known kinds keep their established symbol names")
    func systemImageStability() {
        #expect(CmuxTaskManagerRow.Kind.window.systemImage == "macwindow")
        #expect(CmuxTaskManagerRow.Kind.terminalSurface.systemImage == "terminal")
        #expect(CmuxTaskManagerRow.Kind.childMemoryAggregate.systemImage == "memorychip")
    }
}
