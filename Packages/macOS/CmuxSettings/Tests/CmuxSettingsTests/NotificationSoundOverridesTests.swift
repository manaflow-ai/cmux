import CmuxSettings
import Foundation
import Testing

@Suite("Notification sound overrides")
struct NotificationSoundOverridesTests {
    @Test("missing cells resolve as absent")
    func missingCellsAreAbsent() {
        let overrides = NotificationSoundOverrides()
        #expect(overrides.isEmpty)
        #expect(overrides.override(forAgentID: "claude", alertType: .turnDone) == nil)
    }

    @Test("matrix round trips with custom and built-in cells")
    func roundTrip() throws {
        let custom = try #require(
            NotificationSoundOverride(
                sound: NotificationSoundOverride.customFileValue,
                customSoundFilePath: "~/Sounds/approval.m4r"
            )
        )
        let ping = try #require(NotificationSoundOverride(sound: "Ping"))
        var original = NotificationSoundOverrides()
        original.set(custom, forAgentID: "claude", alertType: .needsInput)
        original.set(ping, forAgentID: "codex", alertType: .turnDone)

        let decoded = try #require(NotificationSoundOverrides(jsonString: original.jsonString))
        #expect(decoded == original)
        #expect(decoded.agentIDs == ["claude", "codex"])
        #expect(decoded.override(forAgentID: "claude", alertType: .needsInput)?.customSoundFilePath == "~/Sounds/approval.m4r")
    }

    @Test("unknown alert types fail closed")
    func unknownAlertTypeFailsClosed() {
        let raw = #"{"claude":{"futureAlert":{"sound":"Ping"}}}"#
        #expect(NotificationSoundOverrides(jsonString: raw) == nil)
    }

    @Test("invalid sound values and empty custom paths are rejected")
    func invalidCellsAreRejected() {
        #expect(NotificationSoundOverride(sound: "Not a system sound") == nil)
        #expect(NotificationSoundOverride(sound: "custom_file", customSoundFilePath: " ") == nil)
        #expect(NotificationSoundOverride(sound: "Ping", customSoundFilePath: "") == nil)
        #expect(NotificationSoundOverride(sound: "Ping", customSoundFilePath: " \t") == nil)
        #expect(NotificationSoundOverride(sound: "Ping", customSoundFilePath: "/tmp/ignored.wav") == nil)
        #expect(NotificationSoundOverrides(jsonString: #"{"claude":{"turnDone":{"sound":"Bogus"}}}"#) == nil)
    }

    @Test("oversized persisted sound matrices fail closed")
    func oversizedJSONIsRejected() {
        let oversizedPath = String(repeating: "a", count: 256 * 1024)
        let raw = "{\"claude\":{\"turnDone\":{\"sound\":\"custom_file\",\"customSoundFilePath\":\"\(oversizedPath)\"}}}"
        #expect(NotificationSoundOverrides(jsonString: raw) == nil)
    }

    @Test("sound matrices reject more than the bounded agent cardinality")
    func oversizedAgentSetIsRejected() {
        let entries = (0...256).map { index in
            "\"agent\(index)\":{\"turnDone\":{\"sound\":\"Ping\"}}"
        }
        let raw = "{\(entries.joined(separator: ","))}"
        #expect(NotificationSoundOverrides(jsonString: raw) == nil)
    }

    @Test("new agent rows are rejected once the matrix is full")
    func setRejectsAgentBeyondBound() throws {
        let ping = try #require(NotificationSoundOverride(sound: "Ping"))
        let initialStorage = (0..<NotificationSoundOverrides.maximumAgentCount).reduce(
            into: [String: [NotificationSoundAlertType: NotificationSoundOverride]]()
        ) { result, index in
            result["agent\(index)"] = [.turnDone: ping]
        }
        var overrides = NotificationSoundOverrides(storage: initialStorage)

        overrides.set(ping, forAgentID: "overflow", alertType: .turnDone)
        #expect(overrides.agentIDs.count == NotificationSoundOverrides.maximumAgentCount)
        #expect(overrides.override(forAgentID: "overflow", alertType: .turnDone) == nil)
        overrides.set(ping, forAgentID: "agent0", alertType: .needsInput)
        #expect(overrides.override(forAgentID: "agent0", alertType: .needsInput) == ping)
    }

    @Test("string decoding checks UTF-8 size before accepting a matrix")
    func oversizedJSONStringFailsBeforeDecode() {
        let oversized = String(repeating: "x", count: NotificationSoundOverrides.maximumJSONBytes)
        let raw = "{\"claude\":{\"turnDone\":{\"sound\":\"custom_file\",\"customSoundFilePath\":\"\(oversized)\"}}}"
        #expect(raw.utf8.count > NotificationSoundOverrides.maximumJSONBytes)
        #expect(NotificationSoundOverrides(jsonString: raw) == nil)
    }

    @Test("settings-file objects are bounded before serialization")
    func oversizedJSONObjectIsRejectedBeforeEncoding() {
        let object: [String: Any] = [
            "claude": [
                "turnDone": [
                    "sound": "custom_file",
                    "customSoundFilePath": String(repeating: "a", count: 256 * 1024),
                ],
            ],
        ]
        #expect(NotificationSoundOverrides.boundedJSONData(fromJSONObject: object) == nil)
    }

    @Test("invalid agent ids cannot create context or matrix cells")
    func invalidAgentIDsFailClosed() throws {
        #expect(NotificationSoundOverrideContext(agentID: "", alertType: .turnDone) == nil)
        #expect(NotificationSoundOverrideContext(agentID: "claude;evil", alertType: .turnDone) == nil)
        #expect(NotificationSoundOverrideContext(agentID: "..", alertType: .turnDone) == nil)

        var overrides = NotificationSoundOverrides()
        let ping = try #require(NotificationSoundOverride(sound: "Ping"))
        overrides.set(ping, forAgentID: "claude;evil", alertType: .turnDone)
        #expect(overrides.isEmpty)
    }

    @Test("agent ids use the notification wire grammar")
    func agentIDsMatchWireGrammar() {
        #expect(NotificationSoundOverrideContext(agentID: "claude-code", alertType: .turnDone) != nil)
        #expect(NotificationSoundOverrideContext(agentID: "Claude-Code", alertType: .turnDone) != nil)
        #expect(
            NotificationSoundOverrideContext(
                agentID: String(repeating: "a", count: 65),
                alertType: .turnDone
            ) == nil
        )
    }

    @Test("decoded context validates the agent id")
    func decodedContextRejectsInvalidAgentID() throws {
        let encoder = JSONEncoder()
        let valid = try encoder.encode(
            try #require(NotificationSoundOverrideContext(agentID: "claude", alertType: .turnDone))
        )
        let decoded = try JSONDecoder().decode(NotificationSoundOverrideContext.self, from: valid)
        #expect(decoded.agentID == "claude")

        let invalid = #"{"agentID":"claude;evil","alertType":"turnDone"}"#.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(NotificationSoundOverrideContext.self, from: invalid)
        }
    }

    @Test("clearing the last cell removes its agent object")
    func clearingCellsRemovesEmptyAgent() throws {
        let ping = try #require(NotificationSoundOverride(sound: "Ping"))
        var overrides = NotificationSoundOverrides()
        overrides.set(ping, forAgentID: "codex", alertType: .errorStalled)
        overrides.set(nil, forAgentID: "codex", alertType: .errorStalled)
        #expect(overrides.isEmpty)
        #expect(overrides.jsonString == "{}")
    }

    @Test("every persisted sound value has a picker descriptor")
    func soundCatalogCoversValidationValues() {
        let catalog = NotificationSoundOptionCatalog()
        let values = Set(catalog.options.map(\.value))
        #expect(values == NotificationSoundOverride.supportedSoundValues)
        #expect(catalog.descriptor(for: "unknown") == nil)
    }
}
