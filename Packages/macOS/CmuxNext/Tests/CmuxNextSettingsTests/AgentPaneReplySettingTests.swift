@testable import CmuxNextSettings
import Testing

/// `agentPane.links.outsideRoots` and `agentPane.images.remote` (D4, D5): the safe defaults
/// when unset, each key on its own, a bad value is that key's default plus a diagnostic, and an
/// agent may change neither.
@Suite struct AgentPaneReplySettingTests {
    private func parse(_ root: JSONValue) -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(root, validDensities: SettingsSchemaTests.densities, validMetrics: [])
    }

    /// Lawrence (2026-10-07, "Remove dialogues."): an outside path opens on the click, with no
    /// sheet; `confirm` stays an opt-in.
    @Test func unsetOpensOnTheClickAndLoadsWebImagesOnClick() throws {
        let setting = parse(.object([:])).agentPaneReplies
        #expect(setting.outsideRoots == .open)
        #expect(setting.remoteImages == .click)
        let outside = try #require(SettingsSchema.descriptor(for: ["agentPane", "links", "outsideRoots"]))
        let images = try #require(SettingsSchema.descriptor(for: ["agentPane", "images", "remote"]))
        #expect(outside.defaultValue == .string("open"))
        #expect(images.defaultValue == .string("click"))
    }

    @Test func everyValueParses() {
        for outside in AgentPaneReplySetting.OutsideRoots.allCases {
            for remote in AgentPaneReplySetting.RemoteImages.allCases {
                let snapshot = parse(["agentPane": ["links": ["outsideRoots": .string(outside.rawValue)],
                                                    "images": ["remote": .string(remote.rawValue)]]])
                #expect(snapshot.diagnostics.isEmpty)
                #expect(snapshot.agentPaneReplies == AgentPaneReplySetting(outsideRoots: outside, remoteImages: remote))
            }
        }
    }

    @Test func badValuesKeepTheirDefaultWithADiagnostic() {
        let snapshot = parse(["agentPane": ["links": ["outsideRoots": "always"], "images": ["remote": "never"]]])
        #expect(snapshot.agentPaneReplies.outsideRoots == .open)
        #expect(snapshot.agentPaneReplies.remoteImages == .never)
        #expect(snapshot.diagnostics.map(\.path) == ["agentPane.links.outsideRoots"])
        #expect(parse(["agentPane": "open"]).diagnostics.map(\.path) == ["agentPane"])
        #expect(parse(["agentPane": ["images": true]]).diagnostics.map(\.path) == ["agentPane.images"])
    }

    @Test func agentsMayNotChangeEither() throws {
        for path in [["agentPane", "links", "outsideRoots"], ["agentPane", "images", "remote"]] {
            let descriptor = try #require(SettingsSchema.descriptor(for: path))
            #expect(SettingsSchema.agentSettable(descriptor) == false)
            #expect(descriptor.section == .general)
        }
    }
}
