import CmuxNextSettings
import Testing

/// The Release login copy's consent (Leo, 2026-11-02: "Consent first"): only the person's own
/// cmux.json says yes; a managed or other layer can only say no.
struct CloudLoginCopyConsentSettingTests {
    let setting = CloudLoginCopyConsentSetting()
    let yes: JSONValue = ["cloud": ["useMyClaudeLoginOnMyCloudMachines": true]]
    let no: JSONValue = ["cloud": ["useMyClaudeLoginOnMyCloudMachines": false]]
    let none: JSONValue = .object([:])

    @Test func onlyThePersonsFileSaysYes() {
        #expect(setting.consent(file: none, effective: none, managed: false) == nil)
        #expect(setting.consent(file: yes, effective: yes, managed: false) == true)
        // A managed or defaults `true` with nothing in the person's file is never consent.
        #expect(setting.consent(file: none, effective: yes, managed: false) == nil)
    }

    @Test func anyLayerMaySayNo() {
        #expect(setting.consent(file: no, effective: no, managed: false) == false)
        // A managed `false` over the person's yes turns the copy off.
        #expect(setting.consent(file: yes, effective: no, managed: false) == false)
        // Any managed source holding the key, whatever its value (a team `false` under an MDM
        // `true` merges to `true`), is no: an organization never consents for the person.
        #expect(setting.consent(file: yes, effective: yes, managed: true) == false)
    }
}

/// The Codex sign-in consent shares the rule: only the person's own cmux.json says yes.
struct CloudCodexSignInConsentSettingTests {
    let setting = CloudCodexSignInConsentSetting()
    let yes: JSONValue = ["cloud": ["useMyCodexLoginOnMyCloudMachines": true]]
    let none: JSONValue = .object([:])

    @Test func onlyThePersonsFileSaysYes() {
        #expect(setting.consent(file: none, effective: none, managed: false) == nil)
        #expect(setting.consent(file: yes, effective: yes, managed: false) == true)
        #expect(setting.consent(file: none, effective: yes, managed: false) == nil)
        #expect(setting.consent(file: yes, effective: yes, managed: true) == false)
        // The Claude answer is not the Codex one.
        #expect(setting.consent(file: ["cloud": ["useMyClaudeLoginOnMyCloudMachines": true]], effective: none, managed: false) == nil)
    }
}
