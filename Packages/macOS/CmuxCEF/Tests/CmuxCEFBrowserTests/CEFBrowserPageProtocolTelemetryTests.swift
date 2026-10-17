import CmuxBrowser
import CmuxCEF
import Foundation
import Testing
@testable import CmuxCEFBrowser

@MainActor
@Suite
struct CEFBrowserPageProtocolTelemetryTests {
    private func makePage() -> CEFBrowserPage {
        let browser = CEFBrowser(configuration: CEFBrowserConfiguration(profile: UUID()))
        return CEFBrowserPage(
            browser: browser,
            shim: { nil },
            devToolsLayoutStore: BrowserDevToolsLayoutStore(
                defaults: UserDefaults(suiteName: "CEFBrowserPageProtocolTelemetryTests.\(UUID().uuidString)")!
            )
        )
    }

    private let consoleEvent = #"{"method":"Runtime.consoleAPICalled","params":{"type":"log","timestamp":1,"args":[{"type":"string","value":"hello"}]}}"#

    @Test func aPageAutomationNeverAskedRecordsNothing() {
        let page = makePage()
        defer { page.close() }
        page.receiveProtocolMessage(consoleEvent)
        #expect(page.protocolTelemetry.consoleEntries.isEmpty)
        #expect(page.protocolTelemetry.recordingStartedAtMS == nil)
    }

    @Test func protocolEventsAreRecordedOnceAutomationStartsTelemetry() {
        let page = makePage()
        defer { page.close() }
        page.startProtocolTelemetry()
        #expect(page.protocolTelemetry.recordingStartedAtMS != nil)
        page.receiveProtocolMessage(consoleEvent)
        #expect(page.protocolTelemetry.consoleEntries.map(\.text) == ["hello"])
        page.clearProtocolTelemetry(console: true, errors: false, network: false)
        #expect(page.protocolTelemetry.consoleEntries.isEmpty)
    }
}
