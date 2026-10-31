@testable import CmuxNextApp
import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextSettings
import Darwin
import Foundation
import Testing

/// acpmux reads only the settings file, so a value MDM forces for `agents.defaultPermissionMode`
/// reaches it only through the app's settings push. The push an MDM-managed app sends to the
/// daemon's socket carries the forced value, marked managed, over the file's own value.
@MainActor @Suite(.serialized) struct ChatSettingsPushPermissionModeTests {
    @Test func thePushCarriesTheValueMDMForcesOverTheFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cnc-push-mode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cmux-next.json")
        try Data(#"{"agents":{"defaultPermissionMode":"fullAccess"}}"#.utf8).write(to: url)
        let forced = ManagedPreferences(forced: ["agents.defaultPermissionMode": .string("ask")])
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(forced), managedWatchFiles: [])
        await settings.reload()

        let daemon = try FakeDaemon()
        defer { daemon.close() }
        ChatSettingsPush.start(settings: settings, socketPath: daemon.path)
        let request = try await daemon.firstUpdate()

        #expect(request["method"]?.stringValue == "_acpmux/chat_settings", "\(request)")
        #expect(request["params"]?["permissionMode"]?.stringValue == "ask", "\(request)")
        #expect(request["params"]?["permissionModeManaged"]?.boolValue == true, "\(request)")
    }

    @Test func withoutPolicyThePushCarriesTheFileValueUnmanaged() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cnc-push-mode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cmux-next.json")
        try Data(#"{"agents":{"defaultPermissionMode":"standard"}}"#.utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()

        let daemon = try FakeDaemon()
        defer { daemon.close() }
        ChatSettingsPush.start(settings: settings, socketPath: daemon.path)
        let request = try await daemon.firstUpdate()

        #expect(request["params"]?["permissionMode"]?.stringValue == "standard", "\(request)")
        #expect(request["params"]?["permissionModeManaged"]?.boolValue == false, "\(request)")
    }

    /// A forced value that is not a string still goes out forced, as a value the daemon does not
    /// know (`""`), which it treats as the harness's own mode: never dropped, which would let the
    /// file or a pick choose full access.
    @Test func aForcedValueThatIsNotAStringIsPushedForcedAndUnknown() {
        let file: JSONValue = .object(["agents": .object(["defaultPermissionMode": .string("fullAccess")])])
        for forced: JSONValue in [.number(1), .bool(true), .null, .object([:])] {
            let managed = ManagedPreferences(forced: ["agents.defaultPermissionMode": forced])
            let effective = EffectiveSettings.merge(file: file, managed: managed, team: .none)
            let chat = ChatSettings(effective: effective.root, file: file, managedRoots: [], managedKeys: effective.managedKeys)
            #expect(chat.params["permissionMode"]?.stringValue == "", "\(forced): \(chat.params)")
            #expect(chat.params["permissionModeManaged"]?.boolValue == true, "\(forced): \(chat.params)")
        }
    }

    /// The team policy's enforced value is forced like MDM's; its default, under a file with no
    /// key, goes out unforced so the daemon starts new chats in what Settings shows.
    @Test func theTeamPolicyEnforcedValueIsPushedForcedAndItsDefaultUnforced() {
        let empty: JSONValue = .object(["agents": .object([:])])
        let enforced = EffectiveSettings.merge(
            file: empty, managed: ManagedPreferences(),
            team: TeamPolicyLayer(teamName: "Acme", enforced: ["agents.defaultPermissionMode": .string("ask")]))
        let forced = ChatSettings(effective: enforced.root, file: empty, managedRoots: [], managedKeys: enforced.managedKeys)
        #expect(forced.params["permissionMode"]?.stringValue == "ask", "\(forced.params)")
        #expect(forced.params["permissionModeManaged"]?.boolValue == true, "\(forced.params)")

        let defaulted = EffectiveSettings.merge(
            file: empty, managed: ManagedPreferences(),
            team: TeamPolicyLayer(teamName: "Acme", defaults: ["agents.defaultPermissionMode": .string("ask")]))
        let unforced = ChatSettings(effective: defaulted.root, file: empty, managedRoots: [], managedKeys: defaulted.managedKeys)
        #expect(unforced.params["permissionMode"]?.stringValue == "ask", "\(unforced.params)")
        #expect(unforced.params["permissionModeManaged"]?.boolValue == false, "\(unforced.params)")
    }
}

/// A unix socket standing in for acpmux: it reads one connection's lines and answers the
/// `_acpmux/chat_settings` request (id 2) as applied.
private nonisolated final class FakeDaemon: @unchecked Sendable {
    let path: String
    private let descriptor: Int32

    init() throws {
        path = NSTemporaryDirectory() + "push-\(UUID().uuidString.prefix(8)).sock"
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EMFILE) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8.prefix(buffer.count - 1))
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(descriptor, 4) == 0 else {
            Darwin.close(descriptor)
            unlink(path)
            throw POSIXError(.EADDRNOTAVAIL)
        }
    }

    /// The first `_acpmux/chat_settings` request a client sends, within 20 seconds. The serving
    /// thread waits with `poll` against the deadline, so a push that never comes ends the test.
    func firstUpdate() async throws -> JSONValue {
        let descriptor = descriptor
        let deadline = Date().addingTimeInterval(20)
        let line: Data? = await withCheckedContinuation { continuation in
            Thread.detachNewThread { continuation.resume(returning: Self.serve(descriptor, until: deadline)) }
        }
        guard let line, let request = try? JSONValue.parse(line) else {
            Issue.record("the push never reached the socket")
            throw POSIXError(.ETIMEDOUT)
        }
        return request
    }

    /// Whether `descriptor` becomes readable before `deadline`.
    private static func readable(_ descriptor: Int32, until deadline: Date) -> Bool {
        while true {
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { return false }
            var entry = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&entry, 1, Int32(min(left, 1) * 1000))
            if ready > 0 { return true }
            if ready < 0, errno != EINTR { return false }
        }
    }

    /// Accepts one connection, reads until the id-2 line, answers it applied; nil past `deadline`.
    private static func serve(_ listener: Int32, until deadline: Date) -> Data? {
        guard readable(listener, until: deadline) else { return nil }
        let client = accept(listener, nil, nil)
        guard client >= 0 else { return nil }
        defer { Darwin.close(client) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                if let message = try? JSONValue.parse(Data(line)), message["id"]?.doubleValue == 2 {
                    let reply = Data(#"{"jsonrpc":"2.0","id":2,"result":{"applied":true}}"#.utf8 + [UInt8(ascii: "\n")])
                    _ = reply.withUnsafeBytes { send(client, $0.baseAddress, reply.count, 0) }
                    return Data(line)
                }
            }
            guard readable(client, until: deadline) else { return nil }
            let count = recv(client, &chunk, chunk.count, 0)
            guard count > 0 else { return nil }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }

    func close() {
        Darwin.close(descriptor)
        unlink(path)
    }
}
