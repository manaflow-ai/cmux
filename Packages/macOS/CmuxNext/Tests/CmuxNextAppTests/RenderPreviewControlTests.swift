import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextApp

@MainActor
@Suite(.serialized)
struct RenderPreviewControlTests {
    @Test func restoredPaneUsesTheAcpmuxSessionInItsRecord() throws {
        _ = NSApplication.shared
        let tabs = AgentTabStore(build: nil, registry: ActionRegistry(),
                                 environment: [AgentPaneSource.devURLVariable: "http://127.0.0.1:9/"], showcase: true)
        tabs.localHost = "install:preview-test"
        let session = "01a148c9-06a4-7820-bb8f-634cbc8d25fc"
        let record = AgentSessionRef(host: "install:preview-test", session: session, harness: "claude")
        let tree = DaemonStore()
        tabs.lookup = { $0 == "restored" ? (record, tree) : nil }
        tabs.listTabs = { [("restored", record)] }
        let view = try #require(tabs.view(for: "restored"))
        #expect(tabs.sessions.isEmpty)
        let control = RenderPreviewControl()
        #expect(control.pane(for: session, in: tabs) === view)
        #expect(control.pane(for: "harness-session-id", in: tabs) == nil)
        tabs.sessions["restored"] = "changed"
        #expect(control.pane(for: session, in: tabs) == nil)
    }

    @Test func realTransportMetadataPassesStrictKeyValidation() async {
        let control = RenderPreviewControl()
        var params: [String: CmuxNextSettings.JSONValue] = [
            "agent_session": .string("own"), "html": .string("<p>Hello</p>"),
            "after": .string("sync"), "origin": .string("script"),
        ]
        do { _ = try await control.capture(params, services: nil); Issue.record("expected no pane") }
        catch let error as ControlError { #expect(error.code == "unavailable") }
        catch { Issue.record("unexpected error: \(error)") }
        params["other"] = .bool(true)
        do { _ = try await control.capture(params, services: nil); Issue.record("expected invalid keys") }
        catch let error as ControlError { #expect(error.code == "invalid_params") }
        catch { Issue.record("unexpected error: \(error)") }
    }
}
