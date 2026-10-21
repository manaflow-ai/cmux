import Foundation
import Testing
@testable import CmuxMobileModel

@Suite struct AccountDetailsTests {
    @Test func membersListYouFirstThenByName() {
        let members = TeamMember.list(
            [("u3", "Zoe Park"), ("u1", nil), ("u2", "  "), ("", "Nobody"), ("u4", "Ana Ruiz")],
            you: (id: "u1", name: "Aziz A")
        )
        #expect(members.map(\.id) == ["u1", "u4", "u2", "u3"])
        #expect(members[0] == TeamMember(id: "u1", name: "Aziz A", isYou: true))
        #expect(members.first { $0.id == "u2" }?.name == "Team member")
        #expect(members.filter(\.isYou).count == 1)
    }

    @Test func youAreListedEvenWhenStackOmitsYou() {
        let members = TeamMember.list([("u2", "Ana Ruiz")], you: (id: "u1", name: "Aziz A"))
        #expect(members.map(\.id) == ["u1", "u2"])
        #expect(members[0].initials == "AA")
    }

    @Test func signInMethodsFromTheStackUser() {
        let methods = SignInMethod.methods(oauthProviderIDs: ["github", "apple", "github", "gitlab"], otpEmail: "me@example.com",
                                           hasPassword: false, hasPasskey: true)
        #expect(methods == [.github, .apple, .oauth("gitlab"), .emailCode("me@example.com"), .passkey])
        #expect(methods.map(\.title) == ["GitHub", "Apple", "Gitlab", "Email code", "Passkey"])
        #expect(methods[3].detail == "me@example.com")
        #expect(SignInMethod.methods(oauthProviderIDs: [], otpEmail: nil, hasPassword: false, hasPasskey: false).isEmpty)
    }

    @MainActor @Test func retiredSettingsAreRemovedAndFontSizeMatchesTheTerminal() throws {
        let suite = "cmuxMobile.settings.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "cmuxMobile.settings.showConnectionDetails")
        defaults.set("Tokyo Night", forKey: "cmuxMobile.settings.terminalTheme")
        let settings = SettingsStore(defaults: defaults)
        #expect(defaults.object(forKey: "cmuxMobile.settings.showConnectionDetails") == nil)
        #expect(defaults.object(forKey: "cmuxMobile.settings.terminalTheme") == nil)
        #expect(settings.terminalFontSize == SettingsStore.defaultTerminalFontSize)
    }
}
