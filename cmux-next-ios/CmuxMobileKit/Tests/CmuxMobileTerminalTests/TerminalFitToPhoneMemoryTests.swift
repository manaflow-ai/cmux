import CmuxMobileDesign
import Foundation
import Testing

/// Fit to Phone per program (Leo, 2026-11-21): a program never toggled follows
/// Settings → Terminal → Fit to Phone; one toggled from the page menu keeps its own.
@Suite struct TerminalFitToPhoneMemoryTests {
    private static func fresh() -> UserDefaults {
        let name = "TerminalFitToPhoneMemoryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func untoggledProgramFollowsTheGlobalSetting() {
        let defaults = Self.fresh()
        let memory = TerminalFitToPhoneMemory(defaults: defaults)
        #expect(memory.fitToPhone(for: "zsh") == CmuxMobilePreferences.defaultTerminalFitToPhone)
        defaults.set(true, forKey: CmuxMobilePreferences.Key.terminalFitToPhone)
        #expect(memory.fitToPhone(for: "zsh"))
        defaults.set(false, forKey: CmuxMobilePreferences.Key.terminalFitToPhone)
        #expect(!memory.fitToPhone(for: "zsh"))
    }

    @Test func programChoiceWinsOverTheGlobalSetting() {
        let defaults = Self.fresh()
        let memory = TerminalFitToPhoneMemory(defaults: defaults)
        memory.set(true, for: "vim")
        defaults.set(false, forKey: CmuxMobilePreferences.Key.terminalFitToPhone)
        #expect(memory.fitToPhone(for: "vim"))
        memory.set(false, for: "vim")
        defaults.set(true, forKey: CmuxMobilePreferences.Key.terminalFitToPhone)
        #expect(!memory.fitToPhone(for: "vim"))
    }

    @Test func programsAreIndependent() {
        let defaults = Self.fresh()
        let memory = TerminalFitToPhoneMemory(defaults: defaults)
        memory.set(true, for: "claude")
        #expect(memory.fitToPhone(for: "claude"))
        #expect(!memory.fitToPhone(for: "codex"))
        memory.set(false, for: "codex")
        #expect(memory.fitToPhone(for: "claude"))
        #expect(!memory.fitToPhone(for: "codex"))
    }

    @Test func choiceIsKeptAcrossInstances() {
        let defaults = Self.fresh()
        TerminalFitToPhoneMemory(defaults: defaults).set(true, for: "htop")
        #expect(TerminalFitToPhoneMemory(defaults: defaults).fitToPhone(for: "htop"))
    }
}
