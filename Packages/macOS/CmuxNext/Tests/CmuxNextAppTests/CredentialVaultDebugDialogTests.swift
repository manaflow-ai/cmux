@testable import CmuxNextApp
import CmuxNextCredentialVault
import CmuxNextDesign
import CmuxNextSettings
import Testing

#if DEBUG || CMUX_BENCH_HOOKS
/// `debug.dialog` (Debug builds) never answers the Credential Vault's sheet for the person and
/// never reports what is typed in a hidden field (cmux issue 26412).
@MainActor @Suite(.serialized) struct CredentialVaultDebugDialogTests {
    @Test func theVaultSheetAnswersOnlyToThePersonAndItsValueIsNeverReported() {
        #expect(DebugDialog.userOnly.isSuperset(of: [CredentialVault.entrySheetIdentifier, CredentialVault.approvalSheetIdentifier,
                                                     CredentialVaultPageRoute.deleteDialogIdentifier]),
                "an agent's `cmux vault` cannot approve itself through debug.dialog")
        let spec = CredentialVault.entrySheet(.init(name: "GH_TOKEN", reason: nil, requester: "the Chief", replaces: false))
        #expect(DebugDialog.secureFields(spec) == [CredentialVault.entryValueField])
    }

    #if DEBUG
    @Test(arguments: ["cloudFixture", "objectMenu", "key", "mouse", "viewKey"])
    func nestedInputHelpersRefuseWhileThePersonEntersACredential(_ helper: String) throws {
        let services = MachineIconTests.services()
        let center = CmuxDialogCenter.shared
        let previousHost = center.host
        center.host = CmuxDialogHeadlessHost()
        var answered = false
        let spec = CredentialVault.entrySheet(.init(name: "GH_TOKEN", reason: nil, requester: "the Chief", replaces: false))
        let id = center.present(spec, in: .app) { _ in answered = true }
        defer {
            center.dismiss(id)
            center.host = previousHost
        }
        let refusal = try #require(DebugDialog.userOnlyInputRefusal)
        let before = try #require(center.record(id))
        let result: JSONValue
        switch helper {
        case "cloudFixture":
            result = DebugCloudMachineFixture.show(["folder": .string("injected\t\r")], services: services)
        case "objectMenu":
            result = DebugObjectMenu.run(["folders": .array([.string("injected\t\r")]), "dismiss": .bool(true)], services: services)
        case "key":
            result = DebugKey.send(["key": .string("return")], services: services)
        case "mouse":
            result = DebugMouse.send(["x": .number(0), "y": .number(0)], services: services)
        default:
            result = DebugViewKey.send(["view": .string("sidebar.focus"), "key": .string("return")], services: services)
        }
        #expect(result == refusal, "nested callers must refuse before resolving a window or synthesizing input")
        #expect(center.record(id) == before)
        #expect(!answered)
    }
    #endif
}
#endif
