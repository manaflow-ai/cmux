@testable import CmuxNextSettings
import Testing

/// `agentPane.dictationEngine`, `agentPane.dictationEngineURL` and `agentPane.dictationEngineModel`:
/// what turns speech into text for cmux's own dictation, Apple's on-device engine (the default,
/// unchanged) or a provider the person brings with their own key. Leo, 2026-11-22: "people should be
/// able to add their own api keys/whatever and toggle that voice mode and whatever to link up to
/// their provider of choice".
struct AgentPaneDictationEngineSettingTests {
    @Test func onDeviceByDefaultAndPersonOnly() {
        let snapshot = CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: [])
        #expect(snapshot.agentPaneComposer.dictationEngine == .onDevice)
        #expect(snapshot.agentPaneComposer.dictationEngineURL == "")
        #expect(snapshot.agentPaneComposer.dictationEngineModel == "")
        let row = SettingsSchema.descriptor(for: AgentPaneComposerSetting.dictationEnginePath)
        #expect(row?.defaultValue == .string("onDevice"))
        // An agent never redirects the person's microphone audio.
        for key in ["agentPane.dictationEngine", "agentPane.dictationEngineURL", "agentPane.dictationEngineModel"] {
            #expect(!SettingsSchema.agentSettableKeys.contains(key))
        }
    }

    @Test func eachEngineRoundTrips() {
        for engine in AgentPaneDictationEngine.allCases {
            let root = JSONValue.object(["agentPane": .object(["dictationEngine": .string(engine.rawValue)])])
            let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
            #expect(snapshot.agentPaneComposer.dictationEngine == engine)
            #expect(!snapshot.diagnostics.contains { $0.path == "agentPane.dictationEngine" })
        }
    }

    /// These strings are also cmux-voice's provider ids, which acpmux reads from the same file.
    @Test func theValuesAreTheProviderIds() {
        let ids = AgentPaneDictationEngine.allCases.map(\.rawValue)
        #expect(ids == ["onDevice", "openai", "groq", "localServer", "whisperCpp", "custom"])
    }

    @Test func aBadEngineIsOnDeviceWithADiagnostic() {
        for bad: JSONValue in [.string("OpenAI"), .string("whisper"), .bool(true), .number(1)] {
            let root = JSONValue.object(["agentPane": .object(["dictationEngine": bad, "showDictation": .bool(false)])])
            let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
            #expect(snapshot.agentPaneComposer.dictationEngine == .onDevice)
            #expect(snapshot.agentPaneComposer.showDictation == false)
            #expect(snapshot.diagnostics.contains { $0.path == "agentPane.dictationEngine" })
        }
    }

    @Test func theURLAndModelAreKept() {
        let root = JSONValue.object(["agentPane": .object([
            "dictationEngine": .string("localServer"),
            "dictationEngineURL": .string("http://127.0.0.1:8000/v1"),
            "dictationEngineModel": .string("parakeet-tdt-0.6b-v2")
        ])])
        let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
        #expect(snapshot.agentPaneComposer.dictationEngine == .localServer)
        #expect(snapshot.agentPaneComposer.dictationEngineURL == "http://127.0.0.1:8000/v1")
        #expect(snapshot.agentPaneComposer.dictationEngineModel == "parakeet-tdt-0.6b-v2")
        #expect(!snapshot.diagnostics.contains { $0.path.hasPrefix("agentPane.dictationEngine") })
    }

    @Test func aURLOrModelThatIsNotTextIsADiagnostic() {
        let root = JSONValue.object(["agentPane": .object(["dictationEngineURL": .bool(true), "dictationEngineModel": .number(3)])])
        let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
        #expect(snapshot.agentPaneComposer.dictationEngineURL == "")
        #expect(snapshot.agentPaneComposer.dictationEngineModel == "")
        #expect(snapshot.diagnostics.contains { $0.path == "agentPane.dictationEngineURL" })
        #expect(snapshot.diagnostics.contains { $0.path == "agentPane.dictationEngineModel" })
    }

    @Test func sitsRightAfterTheSourceOnTheSettingsPage() {
        let keys = SettingsPageLayout.specs.first { $0.id == "chat" }?.groups.flatMap(\.keys) ?? []
        let source = keys.firstIndex(of: "agentPane.dictationSource")
        #expect(source != nil && keys.firstIndex(of: "agentPane.dictationEngine") == source.map { $0 + 1 })
        #expect(source != nil && keys.firstIndex(of: "agentPane.dictationEngineURL") == source.map { $0 + 2 })
        #expect(source != nil && keys.firstIndex(of: "agentPane.dictationEngineModel") == source.map { $0 + 3 })
    }
}
