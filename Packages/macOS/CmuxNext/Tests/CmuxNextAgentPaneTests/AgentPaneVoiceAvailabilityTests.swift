import AppKit
import Testing
@testable import CmuxNextAgentPane

@Suite(.serialized) @MainActor struct AgentPaneVoiceAvailabilityTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    @Test func idleAvailabilityFollowsTheSettingAndPublishesChanges() throws {
        _ = NSApplication.shared
        let model = AgentPaneModel(host: NoHost())
        model.composer.voiceButton = true
        let view = try #require(AgentPaneView(model: model, source: .bundled(URL(filePath: "/dev/null")), chromium: nil))
        defer { view.close() }
        #expect(view.voice.event.value["state"]?.stringValue == "idle")
        #expect(view.voice.event.value["enabled"]?.boolValue == true)
        var scripts: [String] = []
        view.evaluateScript = { scripts.append($0) }
        var setting = model.composer
        setting.voiceButton = false
        setting.push(to: view)
        #expect(view.voice.event.value["enabled"]?.boolValue == false)
        #expect(scripts.contains { $0.hasPrefix("window.cmuxAcpmuxBridge?.voice?.(") && $0.contains("\"enabled\":false") })
        scripts.removeAll()
        setting.voiceButton = true
        setting.push(to: view)
        #expect(view.voice.event.value["enabled"]?.boolValue == true)
        #expect(scripts.contains { $0.hasPrefix("window.cmuxAcpmuxBridge?.voice?.(") && $0.contains("\"enabled\":true") })
    }

    @Test func startCancelAndRestartKeepTheConfiguredControlAvailable() async throws {
        _ = NSApplication.shared
        let pane = try await AgentPaneDelayedSendGestureTests.paneWithChat()
        defer { pane.server.stop(); try? FileManager.default.removeItem(atPath: pane.folder) }
        let registry = AgentPaneVoiceRegistry()
        registry.environment = {
            AcpmuxEnvironment(executable: URL(filePath: "/usr/bin/true"), home: URL(filePath: pane.folder),
                              socketPath: pane.folder + "/unused.sock", daemonArguments: [], childEnvironment: [:])
        }
        let model = AgentPaneModel(host: NoHost(), sessionId: "s-new", transport: pane.transport)
        model.composer.voiceButton = true
        let view = try #require(AgentPaneView(model: model, source: .bundled(URL(filePath: "/dev/null")),
                                            chromium: nil, voiceRegistry: registry))
        defer { view.close() }
        // No suspension between these commands: provider I/O cannot begin before cancellation.
        view.voice.handle(.toggle)
        #expect(view.voice.event.value["state"]?.stringValue == "connecting")
        view.voice.handle(.cancel)
        #expect(view.voice.event.value["state"]?.stringValue == "idle")
        #expect(view.voice.event.value["enabled"]?.boolValue == true)
        view.voice.handle(.toggle)
        #expect(view.voice.event.value["state"]?.stringValue == "connecting")
        view.voice.handle(.restart)
        #expect(view.voice.event.value["state"]?.stringValue == "connecting")
        #expect(view.voice.event.value["enabled"]?.boolValue == true)
        var setting = model.composer
        setting.voiceButton = false
        setting.push(to: view)
        #expect(view.voice.event.value["state"]?.stringValue == "idle")
        #expect(view.voice.event.value["enabled"]?.boolValue == false)
    }
}
