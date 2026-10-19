import AppKit
import CmuxNextActions
@testable import CmuxNextAgentPane
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextSettings
import Foundation
import Testing
import WebKit
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

    @Test(.timeLimit(.minutes(1))) func preparationTimeoutReleasesPaneAndGlobalReservations() async throws {
        _ = NSApplication.shared
        let tabs = AgentTabStore(build: nil, registry: ActionRegistry(),
                                 environment: [AgentPaneSource.devURLVariable: "http://127.0.0.1:9/"], showcase: true)
        tabs.localHost = "install:preparation-timeout"
        let record = AgentSessionRef(host: "install:preparation-timeout", session: "own-chat", harness: "claude")
        let tree = DaemonStore()
        tabs.lookup = { $0 == "preparation-timeout" ? (record, tree) : nil }
        tabs.listTabs = { [("preparation-timeout", record)] }
        let view = try #require(tabs.view(for: "preparation-timeout"))
        let control = RenderPreviewControl()
        let started = AsyncStream<Void>.makeStream()
        let finished = AsyncStream<Void>.makeStream()
        var reply: (@MainActor (Result<Any, any Error>) -> Void)?
        let preparation = AgentPaneRenderPreviewPreparation { completion in
            reply = completion
            started.continuation.yield(())
        }
        let dataStore = WKWebsiteDataStore.nonPersistent()
        let timeout = Task {
            try await ControlDeadline.shared.run(method: "agent.render_preview", deadline: .now + .seconds(1)) { @MainActor in
                defer { finished.continuation.yield(()) }
                return try await control.capture {
                    try await view.renderPreview(html: "<p>Hello</p>", dataStore: dataStore, park: { _ in
                        Issue.record("preparation should not reach capture")
                        return {}
                    }, preparation: preparation)
                }
            }
        }
        var starts = started.stream.makeAsyncIterator()
        _ = await starts.next()
        do { _ = try await timeout.value; Issue.record("expected a preparation timeout") }
        catch let error as ControlError { #expect(error.code == "timeout") }
        catch { Issue.record("unexpected error: \(error)") }
        var finishes = finished.stream.makeAsyncIterator()
        _ = await finishes.next()
        // WebKit may answer after cancellation. It cannot resume or reserve the request again.
        reply?(.success(["document": "late", "width": 640]))
        let rejected = AgentPaneRenderPreviewPreparation { $0(.success(["error": "not_laid_out"])) }
        do {
            _ = try await view.renderPreview(html: "<p>Again</p>", dataStore: dataStore, park: { _ in {} }, preparation: rejected)
            Issue.record("expected the injected preparation error")
        } catch let error as AgentPaneRenderPreviewError { #expect(error == .notLaidOut) }
        catch { Issue.record("unexpected error: \(error)") }
        // Nesting takes both global slots, so even a single leaked permit fails this request.
        let result = try await control.capture {
            _ = try await control.capture { "{}" }
            return "{}"
        }
        #expect(result == .object([:]))
        started.continuation.finish()
        finished.continuation.finish()
    }

}
