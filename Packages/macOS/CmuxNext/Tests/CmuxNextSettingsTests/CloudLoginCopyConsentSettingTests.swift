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
        #expect(setting.consent(file: none, effective: none) == nil)
        #expect(setting.consent(file: yes, effective: yes) == true)
        // A managed or defaults `true` with nothing in the person's file is never consent.
        #expect(setting.consent(file: none, effective: yes) == nil)
    }

    @Test func anyLayerMaySayNo() {
        #expect(setting.consent(file: no, effective: no) == false)
        // A managed `false` over the person's yes turns the copy off.
        #expect(setting.consent(file: yes, effective: no) == false)
    }
}
