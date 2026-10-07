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
        var refused: [String] = ["relative", "~/chats", "/", home, home + "/", "/Volumes/disk", "/Network/server", "/net/server"]
        for folder in guarded {
            refused.append(home + "/" + folder)
            refused.append(home + "/" + folder.lowercased() + "/chat")
        }
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

extension ChatSettingsTests {
    @Test func daemonPayloadUsesEffectiveSwitchesAndSeparateValidatedRoots() throws {
        let file = try JSONC.parse(#"{"agents":{"chats":{"enabled":false,"roots":["/opt/user","relative","/Users/test/Documents/chat"]}}}"#)
        let merged = EffectiveSettings.merge(file: file, managed: .init(forced: [
            "agents.chats.enabled": true, "agents.chats.discovery": false,
            "agents.chats.roots": ["/opt/company", "/Users/test/Library/Mail"],
        ]), team: .none)
        let settings = ChatSettings(effective: merged.root, file: merged.fileRoot, managedRoots: merged.managedChatRoots,
                                    validator: .init(home: "/Users/test", readLink: { _ in nil }))
        let lines = settings.request.split(separator: 0x0A)
        #expect(lines.count == 2)
        let initialize = try JSONValue.parse(Data(lines[0]))
        let update = try JSONValue.parse(Data(lines[1]))
        #expect(initialize["method"] == "initialize")
        #expect(update["method"] == "_acpmux/chat_settings")
        #expect(update["params"] == ["enabled": false, "discovery": false, "roots": ["/opt/user"], "managedRoots": ["/opt/company"]])
        #expect(settings.request.last == 0x0A)
    }

    @Test func refusedSpellingIsNeverResolvedAndSymlinkTargetsAreGuarded() {
        let protected = ChatRootValidator(home: "/Users/test", readLink: { path in
            #expect(path == "/Users" || path == "/Users/test", "Refused spelling must never call readlink: \(path)")
            return nil
        })
        #expect(protected.refusal("/Users/test/Documents/chat") != nil)
        #expect(protected.refusal("relative/chat") != nil)
        let links = ChatRootValidator(home: "/Users/test", readLink: { path in
            #expect(!path.hasPrefix("/Users/test/Documents"))
            return path == "/opt/link" ? "/Users/test/Documents/chats" : nil
        })
        #expect(links.refusal("/opt/link") != nil)
        #expect(links.refusal("/opt/link/child") != nil)
        #expect(links.refusal("/Users/test/code/../Documents/chat") != nil)
        #expect(links.refusal("/Users/test/Desktopish") == nil)
        let homeAlias = ChatRootValidator(home: "/var/home", readLink: { $0 == "/var" ? "/private/var" : nil })
        #expect(homeAlias.refusal("/private/var/home/Documents/chat") != nil)
        #expect(homeAlias.refusal("/private/var/home") != nil)
    }

    @Test func managedAndTeamLayersCannotReenableChatsOrLoseRoots() throws {
        let file: JSONValue = ["agents": ["chats": ["enabled": false, "roots": ["/opt/user"]]]]
        let merged = EffectiveSettings.merge(file: file, managed: .init(forced: [
            "agents.chats.enabled": true, "agents.chats.discovery": true, "agents.chats.roots": ["/opt/device"],
        ]), team: .init(teamName: "Team", enforced: [
            "agents.chats.discovery": false, "agents.chats.roots": ["/opt/team"],
        ]))
        #expect(merged.root.value(at: ["agents", "chats", "enabled"]) == false)
        #expect(merged.root.value(at: ["agents", "chats", "discovery"]) == false)
        #expect(merged.managedChatRoots == ["/opt/team", "/opt/device"])
        #expect(merged.root.value(at: ChatSettings.rootsPath) == ["/opt/user", "/opt/team", "/opt/device"])
    }
}
