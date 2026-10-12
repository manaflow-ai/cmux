import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
@testable import CmuxNextSettings
import Foundation
import Testing

/// Numbered shortcuts (`⌃1…9` Select Tab, `⌃⌥1…9` Select Space) edited from
/// the Keyboard Shortcuts page (cx-w7uu): the row's digit on other modifiers
/// moves the whole family, any other key rebinds that digit alone through
/// keybindings.json; both are in the table again after cmux and the daemon
/// relaunch.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct NumberedShortcutPageTests {
    typealias Launch = KeybindingsFileRelaunchTests.Launch

    static func root(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "cn-\(name)-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: root.appending(path: "cmux.json"))
        return root
    }

    static func key(_ text: String) throws -> Shortcut {
        try #require(KeybindingReports.keys(from: text)?.first)
    }

    /// What the page sends for a row: `{command, key, when, args, replaces}`.
    static func edit(_ row: KeyBinding, to key: String) -> CmuxNextSettings.JSONValue {
        let when = row.when.map { CmuxNextSettings.JSONValue.string($0.text) } ?? .null
        return [
            "command": .string(row.command.rawValue), "key": .string(key), "when": when,
            "args": ["index": .string(row.argument ?? "")],
            "replaces": ["key": .string(KeybindingReports.text(row.keys)), "when": when],
        ]
    }

    /// The family's keys in the table: `digit -> keys` of its entries.
    static func family(_ launch: Launch, _ command: ActionID) -> [String: [String]] {
        var keys: [String: [String]] = [:]
        for entry in RegistryKeyBindings(launch.services.registry).table.entries where entry.command == command {
            var digit = entry.argument ?? "?"
            switch entry.arguments["index"] {
            case .int(let number)?: digit = "\(number)"
            case .string(let text)?: digit = text
            default: break
            }
            keys[digit, default: []].append(KeybindingReports.text(entry.keys))
        }
        return keys
    }

    @Test func aDigitOnNewModifiersMovesTheWholeFamilyAndSurvivesARelaunch() async throws {
        let binary = try #require(SameTreeDaemonBinary.url)
        let root = try Self.root("keyfam")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = "cn-keyfam-\(UUID().uuidString.prefix(8).lowercased())"
        let command = ActionID(rawValue: "selectSurfaceByNumber")
        let ctrl3 = try Self.key("ctrl+3")

        let first = try await Launch(root: root, session: session, binary: binary)
        await first.wait { first.connected }
        let row = try #require(first.entries(command, keys: [ctrl3]).first, "no Select Tab 3 row on ctrl+3")
        var failure: String?
        do {
            _ = try await first.call("cmux.keybindings.set", Self.edit(row, to: "cmd+ctrl+opt+3"))
        } catch {
            failure = String(describing: error)
        }
        let moved = Self.family(first, command)
        await first.quit()
        let expected = Dictionary(uniqueKeysWithValues: (1...9).map { ("\($0)", ["cmd+opt+ctrl+\($0)"]) })
        #expect(failure == nil, "the page refused the move: \(failure ?? "")")
        #expect(moved == expected, "the family did not move to cmd+ctrl+opt")

        let second = try await Launch(root: root, session: session, binary: binary)
        await second.wait { second.connected }
        let relaunched = Self.family(second, command)
        await second.quit()
        #expect(relaunched == expected, "the move was gone after the relaunch")
    }

    @Test func anotherKeyOnADigitRebindsThatDigitAloneInKeybindingsJSON() async throws {
        let binary = try #require(SameTreeDaemonBinary.url)
        let root = try Self.root("keydig")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = "cn-keydig-\(UUID().uuidString.prefix(8).lowercased())"
        let command = ActionID(rawValue: "space.selectByNumber")
        let ctrlOpt2 = try Self.key("ctrl+opt+2")

        let first = try await Launch(root: root, session: session, binary: binary)
        await first.wait { first.connected }
        let row = try #require(first.entries(command, keys: [ctrlOpt2]).first, "no Select Space 2 row on ctrl+opt+2")
        var failure: String?
        do {
            _ = try await first.call("cmux.keybindings.set", Self.edit(row, to: "cmd+ctrl+opt+k"))
        } catch {
            failure = String(describing: error)
        }
        let rebound = Self.family(first, command)
        await first.quit()
        #expect(failure == nil, "the page refused the rebind: \(failure ?? "")")
        #expect(rebound["2"] == ["cmd+opt+ctrl+k"], "digit 2: \(rebound["2"] ?? [])")
        #expect(rebound["3"] == ["opt+ctrl+3"], "the other digits moved: \(rebound)")
        let file = (try? String(contentsOf: root.appending(path: "keybindings.json"), encoding: .utf8)) ?? ""
        #expect(file.contains("space.selectByNumber") && file.contains("cmd+opt+ctrl+k"), "keybindings.json: \(file)")

        let second = try await Launch(root: root, session: session, binary: binary)
        await second.wait { second.connected && Self.family(second, command)["2"] == ["cmd+opt+ctrl+k"] }
        let relaunched = Self.family(second, command)
        await second.quit()
        #expect(relaunched["2"] == ["cmd+opt+ctrl+k"], "the rebind was gone after the relaunch: \(relaunched)")
        #expect(relaunched["3"] == ["opt+ctrl+3"])
    }
}
