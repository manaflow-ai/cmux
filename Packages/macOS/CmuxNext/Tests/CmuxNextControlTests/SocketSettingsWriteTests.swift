import CmuxNextActions
@testable import CmuxNextControl
import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import CmuxNextCompat
import Testing

/// The socket writes settings only through the settings owner
/// (plans/cmux-next/settings-surfaces.md). These iterate `SettingsSchema.all`,
/// so a new descriptor is covered with no edit: it sets, reads back and
/// resets over the socket with schema validation, a value of the wrong type
/// is refused, and a managed key is refused on every write method.
@MainActor @Suite(.serialized) struct SocketSettingsWriteTests {
    func make(managed: ManagedPreferences = ManagedPreferences()) throws -> (ControlRouter, SettingsController, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cnc-settings-surfaces-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(managed), managedWatchFiles: [])
        // The full package suite runs other main-actor tests in parallel. Give
        // this file-backed round trip enough room to cross the actor boundary
        // without changing the production two-second socket deadline.
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor(), settings: settings.file, settingsWriter: settings,
                                   configuration: .init(requestDeadline: .seconds(10)))
        return (router, settings, directory)
    }

    func call(_ router: ControlRouter, _ method: String, _ params: [String: JSONValue] = [:]) async -> Result<JSONValue, ControlError> {
        await router.handle(ControlRequest(id: "1", method: method, params: params))
    }

    /// Each setting round-trips over the socket through the settings owner,
    /// and a value of the wrong type is refused before the file changes.
    @Test func everySettingSetsReadsAndResetsOverTheSocket() async throws {
        let (router, settings, directory) = try make()
        defer { try? FileManager.default.removeItem(at: directory) }
        // User-only keys need `confirm: true` and the person's approval (the sheet approves here).
        settings.userOnlyConfirmation = { _, _ in true }
        for descriptor in SettingsSchema.all {
            let key = JSONValue.string(descriptor.id)
            // The expectation reads the default, not `isUnsetValue`: a write path that dropped every key would
            // also make `isUnsetValue` say "unset", and the round trip would then prove nothing. No MDM or team
            // layer sets a key here, so the build's default is the unset value, except for a key whose reader
            // fills an unset key itself (`unsetIsNotDefault`): a written default stays stored there.
            let defaultValue = settings.defaultValue(of: descriptor)
            let defaultLeavesNoKey = descriptor.sampleValue == defaultValue && !SettingsSchema.unsetIsNotDefault(descriptor.id)
            if defaultLeavesNoKey {
                // The sample is the default, whose write leaves no key (#38119): first write a value that is not
                // the default and read it back, so the file is proven to store this setting.
                guard let other = descriptor.otherSampleValues.first(where: { descriptor.accepts($0) && $0 != defaultValue }) else {
                    Issue.record("\(descriptor.id): no value besides the default to prove a stored write")
                    continue
                }
                let set = await call(router, "settings.set", ["path": key, "value": other, "confirm": true])
                #expect((try? set.get()) != nil, "\(descriptor.id) = \(other): \(set)")
                #expect(try await settings.file.value(at: descriptor.path) == other, "\(descriptor.id) did not store \(other)")
            }
            let before = settings.validatedWrites[descriptor.id, default: 0]
            // A write of the default removes the key (#38119): the file then keeps nothing. `.none`, not a nil
            // literal: JSONValue is ExpressibleByNilLiteral, so `nil` here would be the JSON null, `.null`.
            let stored: JSONValue? = defaultLeavesNoKey ? .none : .some(descriptor.sampleValue)
            let set = await call(router, "settings.set", ["path": key, "value": descriptor.sampleValue, "confirm": true])
            #expect((try? set.get()) != nil, "\(descriptor.id): \(set)")
            #expect(settings.validatedWrites[descriptor.id, default: 0] == before + 1, "\(descriptor.id) skipped the settings owner")
            // value(at:) throws on a file that does not parse; a missing file must not pass for "absent" either.
            let read = try await settings.file.value(at: descriptor.path)
            #expect(read == stored, "\(descriptor.id)")
            if case .none = stored {
                #expect(FileManager.default.fileExists(atPath: directory.appending(path: "cmux.json").path), "\(descriptor.id): cmux.json is gone")
            }
            guard case .failure(let refused) = await call(router, "settings.set", ["path": key, "value": ["wrong": true]]) else {
                Issue.record("\(descriptor.id) accepted a value of the wrong type")
                continue
            }
            #expect(refused.code == "invalid_params", "\(descriptor.id)")
            _ = try await call(router, "settings.reset", ["path": key, "confirm": true]).get()
            #expect(try await settings.file.value(at: descriptor.path) == nil, "\(descriptor.id)")
        }
    }

    /// SECURITY (agent_settable): a socket caller is never the user. A user-only key is refused
    /// with `setting_user_only` (naming --confirm), written only after the person approves the
    /// native sheet, and refused when the sheet is declined; agent-settable keys need no sheet.
    @Test func aUserOnlyKeyNeedsThePersonsApproval() async throws {
        let (router, settings, directory) = try make()
        defer { try? FileManager.default.removeItem(at: directory) }
        var asked: [String] = []
        var approve = false
        settings.userOnlyConfirmation = { key, _ in asked.append(key); return approve }
        // On, not the default off: a write of the default removes the key (#38119), so it would not show the approved write.
        let path: JSONValue = "history.terminalCommands"
        guard case .failure(let refused) = await call(router, "settings.set", ["path": path, "value": true]) else {
            Issue.record("a socket write of a user-only key went through")
            return
        }
        #expect(refused.code == "setting_user_only")
        #expect(refused.message.contains("--confirm"))
        #expect(asked.isEmpty, "no sheet without --confirm")
        guard case .failure(let declined) = await call(router, "settings.set", ["path": path, "value": true, "confirm": true]) else {
            Issue.record("a declined sheet wrote the key")
            return
        }
        #expect(declined.code == "setting_user_only")
        #expect(try await settings.file.value(at: ["history", "terminalCommands"]) == nil)
        approve = true
        _ = try await call(router, "settings.set", ["path": path, "value": true, "confirm": true]).get()
        #expect(try await settings.file.value(at: ["history", "terminalCommands"]) == .bool(true))
        #expect(asked == ["history.terminalCommands", "history.terminalCommands"])
        _ = try await call(router, "settings.set", ["path": "appearance.density", "value": "compact"]).get()
        #expect(asked.count == 2, "an agent-settable key needs no sheet")
        // A socket connection cannot claim user (only in-process callers may).
        let socket = await router.handle(ControlRequest(id: "9", method: "settings.set",
                                                        params: ["path": path, "value": true, "origin": "user"]),
                                         connection: ControlConnectionID(rawValue: 7))
        guard case .failure = socket else {
            Issue.record("a socket caller claimed user")
            return
        }
    }

    /// SECURITY: a write to a parent object that holds a user-only key (`cloud` with the person's
    /// Claude login consent) is the person's to confirm too, never a raw write past the leaf's policy.
    @Test func aParentObjectWriteCannotSetAUserOnlyKeyUnderIt() async throws {
        let (router, settings, directory) = try make()
        defer { try? FileManager.default.removeItem(at: directory) }
        var asked: [String] = []
        settings.userOnlyConfirmation = { key, _ in asked.append(key); return false }
        let value: JSONValue = ["useMyClaudeLoginOnMyCloudMachines": true]
        guard case .failure(let refused) = await call(router, "settings.set", ["path": "cloud", "value": value]) else {
            Issue.record("a parent write set a user-only key")
            return
        }
        #expect(refused.code == "setting_user_only")
        guard case .failure = await call(router, "settings.set", ["path": "cloud", "value": value, "confirm": true]) else {
            Issue.record("a declined sheet wrote the parent")
            return
        }
        #expect(asked.count == 1)
        #expect(try await settings.file.value(at: ["cloud", "useMyClaudeLoginOnMyCloudMachines"]) == nil)
    }

    /// cmux-browser mutes a workspace through settings.set as `script` (a separate process is
    /// never `user`), so `notifications.mutedWorkspaces` is a schema key an agent may set, with no
    /// sheet, and a list that is not workspace-id strings is refused before the file changes.
    @Test func aScriptMutesAWorkspaceThroughSettingsSet() async throws {
        let (router, settings, directory) = try make()
        defer { try? FileManager.default.removeItem(at: directory) }
        var asked: [String] = []
        settings.userOnlyConfirmation = { key, _ in asked.append(key); return false }
        let path: JSONValue = "notifications.mutedWorkspaces"
        let set = await call(router, "settings.set", ["path": path, "value": ["ws-1", "ws-2"], "origin": "script"])
        #expect((try? set.get()) != nil, "\(set)")
        #expect(try await settings.file.value(at: ["notifications", "mutedWorkspaces"]) == ["ws-1", "ws-2"])
        #expect(asked.isEmpty, "an agent-settable key needs no sheet")
        for bad: JSONValue in ["ws-1", [1], [""]] {
            guard case .failure(let refused) = await call(router, "settings.set", ["path": path, "value": bad, "origin": "script"]) else {
                Issue.record("mutedWorkspaces accepted \(bad)")
                continue
            }
            #expect(refused.code == "invalid_params", "\(bad)")
        }
        #expect(try await settings.file.value(at: ["notifications", "mutedWorkspaces"]) == ["ws-1", "ws-2"])
    }

    /// settings.reset and settings.unset wait for the person like settings.set (their own deadline
    /// is the confirmation's, not the 2 s control plane): an approval after the control-plane
    /// deadline still answers the request it writes for.
    @Test func resetAndUnsetWaitForTheSheetPastTheControlPlaneDeadline() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cnc-settings-slow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cmux.json")
        try Data(#"{"history":{"terminalCommands":false}}"#.utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor(), settings: settings.file, settingsWriter: settings,
                                   configuration: .init(requestDeadline: .milliseconds(200)))
        settings.userOnlyConfirmation = { _, _ in
            try? await Task.sleep(for: .milliseconds(500)) // the person takes longer than the control-plane deadline
            return true
        }
        for method in ["settings.reset", "settings.unset"] {
            try Data(#"{"history":{"terminalCommands":false}}"#.utf8).write(to: url)
            await settings.reload()
            let answer = await call(router, method, ["path": "history.terminalCommands", "confirm": true])
            #expect((try? answer.get()) != nil, "\(method): \(answer)")
            #expect(try await settings.file.value(at: ["history", "terminalCommands"]) == nil, "\(method)")
        }
    }

    /// A request whose connection closes while the sheet is open (Ctrl-C) ends the sheet as
    /// declined and writes nothing.
    @Test func aClosedConnectionDismissesTheSheetAndWritesNothing() async throws {
        let (router, settings, directory) = try make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ended = Box()
        let started = Box()
        settings.userOnlyConfirmation = { _, _ in
            started.flag.withLock { $0 = true }
            // The sheet stays open until the request ends; a cancelled sheet answers no.
            await withTaskCancellationHandler {
                while !Task.isCancelled { await Task.yield() }
            } onCancel: { ended.flag.withLock { $0 = true } }
            return false
        }
        let connection = ControlConnectionID(rawValue: 4242)
        async let answer = router.handle(ControlRequest(id: "1", method: "settings.set",
                                                        params: ["path": "history.terminalCommands", "value": false, "confirm": true]),
                                         connection: connection)
        for _ in 0..<10_000 where !started.flag.withLock({ $0 }) { await Task.yield() }
        #expect(started.flag.withLock { $0 }, "the sheet opened")
        ControlConnectionClosures.shared.closed(connection)
        let result = await answer
        guard case .failure(let declined) = result else {
            Issue.record("a closed connection's request wrote: \(result)")
            return
        }
        #expect(declined.code == "setting_user_only")
        #expect(ended.flag.withLock { $0 }, "the sheet was ended")
        #expect(try await settings.file.value(at: ["history", "terminalCommands"]) == nil)
    }

    final class Box: Sendable { let flag = Mutex(false) }

    /// A daemon write and a socket write at the same time both survive. The daemon holds an
    /// exclusive `flock` on `.<file name>.lock` beside the settings file from its read of the file
    /// to its publish (cmux-tui `cmux-config`, `lock_config`); this test is that writer. While it
    /// holds the lock, the socket's `settings.set` must not write: it would edit a text the other
    /// writer is about to replace, and one of the two edits would be lost.
    @Test func aSocketWriteWaitsForTheWriterThatHoldsTheSettingsLock() async throws {
        let (router, settings, directory) = try make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cmux.json")
        let lock = open(directory.appending(path: ".cmux.json.lock").path, O_WRONLY | O_CREAT | O_CLOEXEC, 0o666)
        try #require(lock >= 0, "the lock file opens")
        // Closing the descriptor drops the lock, also when an expectation below throws.
        defer { close(lock) }
        try #require(flock(lock, LOCK_EX) == 0, "the other writer takes the lock")
        let read = try String(contentsOf: url, encoding: .utf8)
        let write = Task {
            await router.handle(ControlRequest(id: "1", method: "settings.set",
                                               params: ["path": "notifications.mutedWorkspaces", "value": ["ws-1"], "origin": "script"]))
        }
        // Room for the socket write to reach the file. Nothing reports "waiting for the lock", so
        // this is a bounded wait: with the lock honored the write cannot finish inside it.
        try await Task.sleep(for: .milliseconds(500))
        #expect(try String(contentsOf: url, encoding: .utf8) == read, "the socket wrote the file while another writer held its lock")
        // The other writer publishes its edit of the text it read, then lets go of the lock.
        try Data(#"{"appearance":{"density":"compact"}}"#.utf8).write(to: url, options: .atomic)
        #expect(flock(lock, LOCK_UN) == 0)
        let answer = await write.value
        #expect((try? answer.get()) != nil, "\(answer)")
        #expect(try await settings.file.value(at: ["notifications", "mutedWorkspaces"]) == ["ws-1"], "the socket write is lost")
        #expect(try await settings.file.value(at: ["appearance", "density"]) == .string("compact"), "the other writer's edit is lost")
    }

    /// A managed key is refused on the socket, schema key or not.
    @Test func aManagedKeyIsRefused() async throws {
        let (router, settings, directory) = try make(managed: ManagedPreferences(forced: ["appearance.density": "compact"]))
        defer { try? FileManager.default.removeItem(at: directory) }
        await settings.reload()
        for method in ["settings.set", "settings.reset", "settings.unset"] {
            guard case .failure(let error) = await call(router, method, ["path": "appearance.density", "value": "comfortable"]) else {
                Issue.record("\(method) wrote a managed key")
                continue
            }
            #expect(error.code == "managed", "\(method)")
        }
    }
}

extension SettingDescriptor {
    /// A value `accepts` takes: the default when there is one, else one that fits the kind.
    var sampleValue: JSONValue {
        if let defaultValue, accepts(defaultValue) { return defaultValue }
        switch kind {
        case .choice(let choices): return .string(choices.first?.value ?? "")
        case .choiceOrNumber(let choices, let number): return choices.first.map { .string($0.value) } ?? .number(number.range.lowerBound)
        case .choiceOrURL(let choices, let urlKey): return choices.first.map { .string($0.value) } ?? .object([urlKey: .string("http://mini.tail1234.ts.net:7320")])
        case .toggle: return .bool(false)
        case .number(let number): return .number(number.range.lowerBound)
        case .color: return .string("#336699")
        case .sound: return .string("default")
        case .url: return .string("")
        case .hostList, .folderList, .numberList, .stringList, .orderedChoices, .choiceSet: return .array([])
        case .stringMap, .soundRules: return .object([:])
        case .timeRange: return .object(["start": .string("22:00"), "end": .string("07:00")])
        case .theme: return .string("Dracula")
        case .fontFamily: return .string("Menlo")
        case .text: return .string("TextEdit")
        }
    }

    /// Candidate values besides `sampleValue`, in the order the round trip tries them: it writes the first one
    /// `accepts` takes that is not the default, so a setting whose sample is its default still proves the file
    /// stores a value. A key with its own validator gets candidates that validator takes.
    var otherSampleValues: [JSONValue] {
        if path == CustomDensitiesSetting.configPath { return [.array([.object(["id": "my-tight", "name": "My Tight"])])] }
        if path == CommandLabelsSetting().configPath { return [.array(["cmux-fleet"])] }
        if path == ChatSettings.rootsPath { return [.array(["/opt/cmux-test-chats"]), .array([])] }
        switch kind {
        case .choice(let choices): return choices.map { .string($0.value) }
        case .choiceOrNumber(let choices, let number):
            return choices.map { .string($0.value) } + [.number(number.range.lowerBound), .number(number.range.upperBound)]
        case .choiceOrURL(let choices, let urlKey):
            return choices.map { .string($0.value) } + [.object([urlKey: .string("http://mini.tail1234.ts.net:7320")])]
        case .toggle: return [.bool(true), .bool(false)]
        case .number(let number): return [.number(number.range.lowerBound), .number(number.range.upperBound)]
        case .color: return [.string("#336699"), .string("#112233")]
        case .sound: return [.string("default"), .string("Glass")]
        case .url: return [.string(""), .string("https://example.com/search?q=%s"), .string("https://example.com")]
        case .hostList: return [.array([]), .array([.string("devbox.local")])]
        case .folderList: return [.array([]), .array([.string("~/src")])]
        case .numberList(let number): return [.array([]), .array([.number(number.range.lowerBound)])]
        case .stringList: return [.array([]), .array([.string("cmux")])]
        case .orderedChoices(let choices), .choiceSet(let choices):
            return [.array([]), .array(choices.prefix(1).map { .string($0.value) }), .array(choices.reversed().map { .string($0.value) })]
        case .stringMap: return [.object([:]), .object(["cmux": .string("cmux")])]
        case .soundRules: return [.object([:]), .object(["cmux": .string("Glass")])]
        case .timeRange:
            return [.object(["start": .string("22:00"), "end": .string("07:00")]), .object(["start": .string("23:00"), "end": .string("06:00")])]
        case .theme: return [.string("Dracula"), .string("Nord")]
        case .fontFamily: return [.string("Menlo"), .string("Monaco")]
        case .text: return [.string("TextEdit"), .string("Xcode")]
        }
    }
}
