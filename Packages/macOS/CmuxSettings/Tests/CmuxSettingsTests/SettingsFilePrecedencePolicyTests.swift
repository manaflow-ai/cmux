import Testing
@testable import CmuxSettings

@Suite struct SettingsFilePrecedencePolicyTests {
    private let policy = SettingsFilePrecedencePolicy()
    private let terminal = TerminalCatalogSection()

    @Test(arguments: [false, true])
    func unchangedTextBoxValuesApplyOnlyWithFileAuthority(_ authority: Bool) {
        let values = [
            terminal.showTextBoxOnNewTerminals.userDefaultsKey: true,
            terminal.focusTextBoxOnNewTerminals.userDefaultsKey: true,
            terminal.copyOnSelect.userDefaultsKey: true,
        ]
        let expected: Set<String> = authority ? [
            terminal.showTextBoxOnNewTerminals.userDefaultsKey,
            terminal.focusTextBoxOnNewTerminals.userDefaultsKey,
        ] : []

        #expect(policy.keysToApply(
            previous: values,
            next: values,
            appliesFileAuthority: authority
        ) == expected)
    }

    @Test(arguments: [false, true])
    func changedAndAddedValuesApplyWithoutForcingRemovedKeys(_ authority: Bool) {
        let previous = [
            terminal.showTextBoxOnNewTerminals.userDefaultsKey: true,
            terminal.focusTextBoxOnNewTerminals.userDefaultsKey: true,
            terminal.copyOnSelect.userDefaultsKey: false,
        ]
        let next = [
            terminal.copyOnSelect.userDefaultsKey: true,
            terminal.showScrollBar.userDefaultsKey: false,
        ]

        #expect(policy.keysToApply(
            previous: previous,
            next: next,
            appliesFileAuthority: authority
        ) == Set(next.keys))
    }
}
