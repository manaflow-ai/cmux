@testable import CmuxNextSettings
import Foundation
import Testing

@Suite struct ChatSettingsTests {
    private func row(_ name: String) throws -> SettingDescriptor {
        try #require(SettingsSchema.descriptor(for: ["agents", "chats", name]))
    }

    @Test func schemaDefaultsAndPrivacy() throws {
        for (name, value) in [("enabled", JSONValue.bool(true)), ("discovery", .bool(true)), ("roots", .array([]))] {
            let descriptor = try row(name)
            #expect(descriptor.defaultValue == value)
            #expect(SettingsSchema.agentRefusedKeys[descriptor.id] == .privacy)
            #expect(SettingsSchema.agentSettable(descriptor) == false)
        }
    }

    @Test func refusesEveryProtectedClassAndRelativePaths() throws {
        let descriptor = try row("roots")
        let home = NSHomeDirectory()
        let guarded = ["Desktop", "Documents", "Downloads", "Pictures", "Music", "Movies",
                       "Library/Mobile Documents", "Library/CloudStorage", "Library/Containers",
                       "Library/Group Containers", "Library/Mail", "Library/Messages", "Library/Safari", "Library/Calendars"]
        let refused = ["relative", "~/chats", "/", home, home + "/", "/Volumes/disk", "/Network/server", "/net/server"]
            + guarded.flatMap { [home + "/" + $0, home + "/" + $0.lowercased() + "/chat"] }
        for path in refused {
            #expect(!descriptor.accepts(.array([.string(path)])), "must refuse \(path)")
        }
        for path in [home + "/.codex", home + "/Desktopish", "/opt/chat-settings-test"] {
            #expect(descriptor.accepts(.array([.string(path)])))
        }
        #expect(!descriptor.accepts(.array([.number(2)])))
    }

    @Test func managedRootsAddWithoutLockingUserRoots() throws {
        let file = try JSONC.parse(#"{"agents":{"chats":{"roots":["/opt/user","/opt/shared"]}}}"#)
        let merged = EffectiveSettings.merge(file: file, managed: .init(forced: [
            "agents.chats.roots": .array([.string("/opt/shared"), .string("/opt/managed")]),
        ]), team: .none)
        #expect(merged.root.value(at: ["agents", "chats", "roots"]) == .array([
            .string("/opt/user"), .string("/opt/shared"), .string("/opt/managed"),
        ]))
        #expect(merged.fileRoot == file)
        #expect(merged.managedKeys["agents.chats.roots"] == nil)
        #expect(!merged.diagnostics.contains { $0.path == "agents.chats.roots" && $0.kind == .managedOverride })
    }

    @Test func managedBooleansCanOnlyForceOff() throws {
        for name in ["enabled", "discovery"] {
            for user in [false, true] {
                for managed in [false, true] {
                    let key = "agents.chats.\(name)"
                    let file: JSONValue = ["agents": ["chats": .object([name: .bool(user)])]]
                    let merged = EffectiveSettings.merge(file: file, managed: .init(forced: [key: .bool(managed)]), team: .none)
                    #expect(merged.root.value(at: ["agents", "chats", name]) == .bool(user && managed))
                    #expect((merged.managedKeys[key] != nil) == !managed)
                }
            }
        }
    }
}
