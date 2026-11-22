public import CmuxNextSettings
import Foundation
import Synchronization

/// Who a socket settings write acts for, and its refusals (SECURITY, agent_settable). Its own
/// type, not a `ControlRouter` member (that type's line budget is full).
enum ControlSettingsPolicy {
    /// `call`'s writer: the request's checked `origin` (`user` only in process), else `cli`. A
    /// socket caller is never the user; `confirm: true` asks the person on a native sheet.
    static func writer(_ call: ControlCall) throws -> SettingWriter {
        let origin = try ControlOrigin().validated(call.params["origin"], connection: call.connection) ?? "cli"
        return origin == "user" ? .user : .caller(origin)
    }

    /// The refusal of a user-only key, with the two ways a person can change it.
    static func userOnly(_ key: String) -> ControlError {
        ControlError(code: "setting_user_only", message: ControlStrings.format(
            "control.error.settingUserOnly",
            "%1$@ can be changed only by you: use Settings, or `cmux settings set %1$@ <value> --confirm` and approve it in cmux",
            key), data: ["key": .string(key)])
    }

    static func declined(_ key: String) -> ControlError {
        ControlError(code: "setting_user_only", message: ControlStrings.format(
            "control.error.settingUserOnlyDeclined", "%1$@ was not changed: the confirmation was declined", key),
            data: ["key": .string(key), "declined": true])
    }

    /// The person's approval of a user-only write, ended (declined, sheet dismissed, nothing
    /// written) when the request ends first: its deadline passed (the task is cancelled) or its
    /// connection closed (Ctrl-C). A write nobody waits for never happens.
    @MainActor
    static func confirm(_ key: String, value: JSONValue?, owner: any ControlSettingsWriter,
                        connection: ControlConnectionID) async -> Bool {
        let sheet = Task { @MainActor in await owner.confirmUserOnlyWrite(key: key, value: value) }
        let token = ControlConnectionClosures.shared.add(connection) { sheet.cancel() }
        defer { ControlConnectionClosures.shared.remove(token) }
        let approved = await withTaskCancellationHandler { await sheet.value } onCancel: { sheet.cancel() }
        return approved && !Task.isCancelled && !sheet.isCancelled
    }
}

/// Work to end when a control connection closes (the server calls ``closed(_:)``): a request still
/// waiting on that connection, such as a confirmation sheet, stops instead of finishing for nobody.
public final class ControlConnectionClosures: Sendable {
    public static let shared = ControlConnectionClosures()

    public struct Token: Sendable, Hashable {
        let connection: ControlConnectionID
        let id: UInt64
    }

    private struct State {
        var next: UInt64 = 0
        var handlers: [ControlConnectionID: [UInt64: @Sendable () -> Void]] = [:]
    }

    private let state = Mutex(State())

    public init() {}

    /// Runs `handler` when `connection` closes (never for the in-process connection).
    public func add(_ connection: ControlConnectionID, _ handler: @escaping @Sendable () -> Void) -> Token {
        state.withLock { state in
            state.next += 1
            if connection != .inProcess { state.handlers[connection, default: [:]][state.next] = handler }
            return Token(connection: connection, id: state.next)
        }
    }

    public func remove(_ token: Token) {
        _ = state.withLock { $0.handlers[token.connection]?.removeValue(forKey: token.id) }
    }

    /// `connection` closed: runs and drops its handlers.
    public func closed(_ connection: ControlConnectionID) {
        let handlers = state.withLock { $0.handlers.removeValue(forKey: connection) } ?? [:]
        for handler in handlers.values { handler() }
    }
}
