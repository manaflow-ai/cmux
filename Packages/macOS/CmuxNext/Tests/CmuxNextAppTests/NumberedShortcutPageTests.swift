import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextPages
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

    static func root(_ name: String, settings: String = "{}") throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "cn-\(name)-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(settings.utf8).write(to: root.appending(path: "cmux.json"))
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

    /// Select Tab moves to ⌘⌥ (docs/configuration.md's way to give Ctrl+digits back to
    /// terminal programs). ⌃⌥⌘1…9 are Select Space's extra keys since ac2557f40b2, so the
    /// page refuses them as part of a numbered family.
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
            _ = try await first.call("cmux.keybindings.set", Self.edit(row, to: "cmd+opt+3"))
        } catch {
            failure = String(describing: error)
        }
        let moved = Self.family(first, command)
        await first.quit()
        let expected = Dictionary(uniqueKeysWithValues: (1...9).map { ("\($0)", ["cmd+opt+\($0)"]) })
        #expect(failure == nil, "the page refused the move: \(failure ?? "")")
        #expect(moved == expected, "the family did not move to cmd+opt")

        let second = try await Launch(root: root, session: session, binary: binary)
        await second.wait { second.connected }
        let relaunched = Self.family(second, command)
        await second.quit()
        #expect(relaunched == expected, "the move was gone after the relaunch")
    }

    /// Another key on one digit of Select Space binds that digit alone, in keybindings.json, and
    /// the rest of the family is unchanged. Select Space's extra keys Ctrl-Opt-Cmd-1…9 (ac2557f40b2,
    /// `KeyBindingDefaults.spaceAliases`) stay: `KeyBindingDefaults.entries` drops an action's
    /// aliases only for a cmux.json override or a chord, never for a keybindings.json line. So
    /// digit 2 has Ctrl-Opt-Cmd-2 and the new key; every other digit keeps Ctrl-Opt-N and Ctrl-Opt-Cmd-N.
    @Test func anotherKeyOnADigitRebindsThatDigitAloneInKeybindingsJSON() async throws {
        let binary = try #require(SameTreeDaemonBinary.url)
        let root = try Self.root("keydig")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = "cn-keydig-\(UUID().uuidString.prefix(8).lowercased())"
        let command = ActionID(rawValue: "space.selectByNumber")
        let ctrlOpt2 = try Self.key("ctrl+opt+2")
        var expected = Dictionary(uniqueKeysWithValues: (1...9).map { ("\($0)", Set(["opt+ctrl+\($0)", "cmd+opt+ctrl+\($0)"])) })
        expected["2"] = ["cmd+opt+ctrl+2", "cmd+opt+ctrl+k"]
        let keys = { (launch: Launch) in Self.family(launch, command).mapValues(Set.init) }

        let first = try await Launch(root: root, session: session, binary: binary)
        await first.wait { first.connected }
        let row = try #require(first.entries(command, keys: [ctrlOpt2]).first, "no Select Space 2 row on ctrl+opt+2")
        var failure: String?
        do {
            _ = try await first.call("cmux.keybindings.set", Self.edit(row, to: "cmd+ctrl+opt+k"))
        } catch {
            failure = String(describing: error)
        }
        let rebound = keys(first)
        await first.quit()
        #expect(failure == nil, "the page refused the rebind: \(failure ?? "")")
        #expect(rebound == expected, "after the rebind: \(rebound)")
        let file = (try? String(contentsOf: root.appending(path: "keybindings.json"), encoding: .utf8)) ?? ""
        #expect(file.contains("space.selectByNumber") && file.contains("cmd+opt+ctrl+k"), "keybindings.json: \(file)")

        let second = try await Launch(root: root, session: session, binary: binary)
        // Until the relaunch read keybindings.json (its key is in the table), not until the whole
        // expected state: a wrong family fails at once instead of at the wait's limit.
        await second.wait { second.connected && keys(second)["2"]?.contains("cmd+opt+ctrl+k") == true }
        let relaunched = keys(second)
        await second.quit()
        #expect(relaunched == expected, "after the relaunch: \(relaunched)")
    }

    /// Onboarding's Spaces scheme keeps both families in cmux.json: one digit
    /// of Select Tab still rebinds alone, and the other eight keep their keys.
    @Test func aDigitOfAFamilyCmuxJSONHoldsRebindsAloneAndSurvivesARelaunch() async throws {
        let binary = try #require(SameTreeDaemonBinary.url)
        let root = try Self.root("keyjs", settings: #"{"shortcuts": {"bindings": {"space.selectByNumber": "ctrl+1", "selectSurfaceByNumber": "ctrl+opt+1"}}}"#)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = "cn-keyjs-\(UUID().uuidString.prefix(8).lowercased())"
        let command = ActionID(rawValue: "selectSurfaceByNumber")
        let ctrlOpt3 = try Self.key("ctrl+opt+3")
        var expected = Dictionary(uniqueKeysWithValues: (1...9).map { ("\($0)", ["opt+ctrl+\($0)"]) })
        expected["3"] = ["cmd+opt+ctrl+k"]

        let first = try await Launch(root: root, session: session, binary: binary)
        await first.wait { first.connected }
        let row = try #require(first.entries(command, keys: [ctrlOpt3]).first, "no Select Tab 3 row on ctrl+opt+3")
        var failure: String?
        do {
            _ = try await first.call("cmux.keybindings.set", Self.edit(row, to: "cmd+ctrl+opt+k"))
        } catch {
            failure = String(describing: error)
        }
        let rebound = Self.family(first, command)
        await first.quit()
        #expect(failure == nil, "the page refused the rebind: \(failure ?? "")")
        #expect(rebound == expected, "\(rebound)")

        let second = try await Launch(root: root, session: session, binary: binary)
        await second.wait { second.connected && Self.family(second, command) == expected }
        let relaunched = Self.family(second, command)
        await second.quit()
        #expect(relaunched == expected, "after the relaunch: \(relaunched)")
    }

    /// A digit rebound onto another digit's key would take that key from it:
    /// the page refuses, and the family is unchanged.
    @Test func aDigitOnAnotherDigitsKeyIsRefused() async throws {
        let binary = try #require(SameTreeDaemonBinary.url)
        let root = try Self.root("keysib")
        defer { try? FileManager.default.removeItem(at: root) }
        let command = ActionID(rawValue: "selectSurfaceByNumber")
        let launch = try await Launch(root: root, session: "cn-keysib-\(UUID().uuidString.prefix(8).lowercased())", binary: binary)
        await launch.wait { launch.connected }
        let row = try #require(launch.entries(command, keys: [try Self.key("ctrl+2")]).first)
        var code: String?
        do {
            _ = try await launch.call("cmux.keybindings.set", Self.edit(row, to: "ctrl+3"))
        } catch let error as PageError {
            code = error.code
        }
        let family = Self.family(launch, command)
        await launch.quit()
        #expect(code == "cmux.keybindings.conflict")
        #expect(family == Dictionary(uniqueKeysWithValues: (1...9).map { ("\($0)", ["ctrl+\($0)"]) }), "\(family)")
    }

    /// Recording a family's own keys again writes nothing to cmux.json.
    @Test func reRecordingAFamilysOwnKeyWritesNothing() async throws {
        let binary = try #require(SameTreeDaemonBinary.url)
        let root = try Self.root("keysame")
        defer { try? FileManager.default.removeItem(at: root) }
        let command = ActionID(rawValue: "selectWorkspaceByNumber")
        let launch = try await Launch(root: root, session: "cn-keysame-\(UUID().uuidString.prefix(8).lowercased())", binary: binary)
        await launch.wait { launch.connected }
        let row = try #require(launch.entries(command, keys: [try Self.key("cmd+3")]).last)
        var failure: String?
        do {
            _ = try await launch.call("cmux.keybindings.set", Self.edit(row, to: "cmd+3"))
        } catch {
            failure = String(describing: error)
        }
        let overridden = launch.services.registry.shortcutOverrides.keys.contains(command)
        await launch.quit()
        let settings = (try? String(contentsOf: root.appending(path: "cmux.json"), encoding: .utf8)) ?? ""
        #expect(failure == nil, "\(failure ?? "")")
        #expect(!overridden && !settings.contains("selectWorkspaceByNumber"), "cmux.json: \(settings)")
    }
}
