#if os(iOS)
import Testing
@testable import CmuxMobileShellUI

@MainActor
@Suite struct TaskTemplateIconTests {
    @Test func bundledAgentBrandImagesLoad() {
        #expect(TaskTemplateIcon.brandImage(baseName: "Claude", darkMode: false) != nil)
        #expect(TaskTemplateIcon.brandImage(baseName: "Codex", darkMode: false) != nil)
        #expect(TaskTemplateIcon.brandImage(baseName: "Codex", darkMode: true) != nil)
        #expect(TaskTemplateIcon.brandImage(baseName: "OpenCode", darkMode: false) != nil)
    }
}
#endif
