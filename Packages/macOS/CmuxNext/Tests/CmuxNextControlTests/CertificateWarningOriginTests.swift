import CmuxNextActions
@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import Testing

/// Coordinator decision: Proceed past a certificate warning runs only from
/// a person in the app (the warning page's button, the palette, a menu, a
/// shortcut). The control socket (`cmux action run`, MCP, the debug socket)
/// refuses it whatever origin the caller claims; Go Back runs from any
/// origin.
@MainActor
@Suite struct CertificateWarningOriginTests {
    @Test func proceedIsRefusedOverTheSocketAndGoBackRuns() async {
        let registry = ActionRegistry.standard()
        registry.context = [.browserFocused]
        var ran: [String] = []
        registry.bind("browser.certificateWarning.proceed", invoke: { _ in ran.append("proceed") })
        registry.bind("browser.certificateWarning.goBack", invoke: { _ in ran.append("goBack") })
        let router = ControlRouter(identity: testIdentity(), executor: RegistryControlBridge(registry: registry), settings: nil,
                                   configuration: .loadTolerant)
        router.updateCatalog(RegistryControlBridge.catalog(from: registry))
        let personOnly = ControlStrings.text("control.error.personOnly", "Only a person in cmux can run this action")
        for origin: JSONValue in ["user", "cli", "mcp", "script", .null] {
            let result = await router.handle(ControlRequest(id: "1", method: "action.run", params: [
                "action": "browser.certificateWarning.proceed", "origin": origin,
            ]))
            switch result {
            case .success(let value):
                Issue.record("proceed from \(origin): expected the person-only refusal, got \(value)")
            case .failure(let error):
                #expect(error.code == "unavailable", "\(origin)")
                #expect(error.data?["reason"] == .string(personOnly), "\(origin)")
            }
        }
        #expect(ran.isEmpty, "the handler never runs for a socket caller")

        let back = await router.handle(ControlRequest(id: "2", method: "action.run", params: [
            "action": "browser.certificateWarning.goBack", "origin": "mcp",
        ]))
        if case .failure(let error) = back { Issue.record("goBack from mcp: \(error.message)") }
        #expect(ran == ["goBack"])
    }

    /// In the app (palette, menu, shortcut, the warning page's button) the
    /// registry runs Proceed.
    @Test func proceedRunsForAPersonInTheApp() {
        let registry = ActionRegistry.standard()
        registry.context = [.browserFocused]
        var ran = false
        registry.bind("browser.certificateWarning.proceed", invoke: { _ in ran = true })
        #expect(registry.perform("browser.certificateWarning.proceed"))
        #expect(ran)
        #expect(registry.descriptor(for: "browser.certificateWarning.proceed")?.isPersonOnly == true)
        #expect(registry.descriptor(for: "browser.certificateWarning.goBack")?.isPersonOnly == false)
    }
}
