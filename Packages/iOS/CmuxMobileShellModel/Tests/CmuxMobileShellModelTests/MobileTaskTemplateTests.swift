import Foundation
import Testing
@testable import CmuxMobileShellModel

@Suite struct MobileTaskTemplateTests {
    @Test func seedDefaultsUseExpectedNamesIconsAndCommands() {
        let seeds = MobileTaskTemplate.seedDefaults(
            claudeName: "Claude",
            codexName: "Codex",
            shellName: "Shell"
        )

        #expect(seeds.map(\.name) == ["Claude", "Codex", "Shell"])
        #expect(seeds.map(\.icon) == ["brain.head.profile", "sparkles", "terminal"])
        #expect(seeds.map(\.command) == ["claude", "codex", ""])
        #expect(seeds.allSatisfy { $0.defaultDirectory == nil })
    }

    @Test func templateCodableRoundTripsEditableFields() throws {
        let id = UUID()
        let template = MobileTaskTemplate(
            id: id,
            name: "Build",
            icon: "hammer",
            command: "swift test",
            defaultDirectory: "~/code/cmux"
        )

        let data = try JSONEncoder().encode(template)
        let decoded = try JSONDecoder().decode(MobileTaskTemplate.self, from: data)

        #expect(decoded == template)
    }
}
