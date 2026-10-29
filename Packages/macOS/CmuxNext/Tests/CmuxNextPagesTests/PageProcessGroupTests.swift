@testable import CmuxNextPages
import Testing

/// The pages declared in CmuxNextPages are in their capability group (p13-webui.md 3.B as task 087 corrects it); the
/// app's PageProcessGroupTableTests checks all 22.
@Suite struct PageProcessGroupTests {
    @Test func thePagesOfThisModuleAreInTheirGroups() {
        let expected: [(PageDescriptor, PageProcessGroup)] = [
            (.cloud, .privileged), (.apps, .privileged), (.coderouter, .privileged),
            (.history, .privileged), (.stats, .privileged), (.chiefUsage, .privileged),
            // Files acts (`open`) while it shows repository text, so task 087's audit makes it solo.
            (.diff, .solo), (.editor, .solo), (.changelog, .solo), (.markdown, .solo), (.settings, .solo), (.files, .solo),
        ]
        for (page, group) in expected {
            #expect(page.processGroup == group, "\(page.id) is in \(page.processGroup)")
        }
    }

    @Test func soloAndSecretsNeverShareARenderer() {
        #expect(PageProcessGroup.allCases.filter { !$0.sharesRenderer } == [.solo, .secrets])
    }

    @Test func anAppPageSharesWithNoOtherPage() throws {
        let page = try PageDescriptor.appPage(id: "com.example.app", resource: "app", namespaces: ["com.example.app."])
        #expect(page.processGroup == .solo)
    }
}
