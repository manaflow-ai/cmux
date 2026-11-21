public import AppKit
public import CmuxNextSettings
import Foundation

// The app's control socket calls `machine.list` and `device.join_line` (AppControl+Remote): the
// Machines section's machines and Add Device's join line, read the way the person sees them, for
// scripts and the end-to-end checks that drive a real app. Each is one read or one press on a
// trigger; nothing here repeats on its own, and nothing here writes the line to a log.

extension MachineSectionRow {
    /// One machine as `machine.list` answers it: `id` (what `machine.reconnect` and New Workspace take;
    /// `joined:<id>` for a machine reached through the hub alone), `name`, `kind`, `isLocal`, `linkState`
    /// (a `MachineLinkState` word from the sidebar rule `row_link`; null when it did not answer), `online`,
    /// `serverState`, and `joined` (the hub's row) for a machine that joined through the hub.
    public func automationJSON(linkState: String?) -> JSONValue {
        var joinedJSON: JSONValue = .null
        if let joined {
            var fields: [String: JSONValue] = ["id": .string(joined.id), "name": .string(joined.name), "state": .string(joined.state.rawValue)]
            for (key, value) in [("meshPeerId", joined.meshPeerId), ("joinTokenId", joined.joinTokenId), ("platform", joined.platform),
                                 ("hostname", joined.hostname), ("lastHeartbeat", joined.lastHeartbeat)] {
                if let value { fields[key] = .string(value) }
            }
            joinedJSON = .object(fields)
        }
        return .object([
            "id": .string(id), "name": .string(name), "kind": .string(kind.rawValue), "isLocal": .bool(isLocal),
            "linkState": linkState.map(JSONValue.string) ?? .null, "online": .bool(isConnected),
            "serverState": serverState.map { .string($0.rawValue) } ?? .null, "joined": joinedJSON,
        ])
    }
}

extension MachineJoinLineModel.Phase {
    /// Whether the card's Make Line (or New Line) is its press now: never over a line still showing.
    public var mintsOnPress: Bool {
        switch self {
        case .idle, .expired, .failed: true
        case .minting, .showing, .joined: false
        }
    }

    /// The phase as the card shows it: `phase`, and with a line its `line`, `joinTokenId`, `expiresAt`
    /// (RFC 3339), `secondsLeft` and `name`; after the flip the `joined` machine and its `checks`, and no line.
    public func automationJSON(checks: [HostStepResult], now: Date) -> [String: JSONValue] {
        switch self {
        case .idle: return ["phase": .string("idle")]
        case .minting: return ["phase": .string("minting")]
        case .expired: return ["phase": .string("expired")]
        case let .failed(failure): return ["phase": .string("failed"), "failure": .string(String(describing: failure))]
        case let .showing(line):
            let format = ISO8601DateFormatter()
            format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return ["phase": .string("showing"), "line": .string(line.line), "joinTokenId": .string(line.joinTokenId),
                    "expiresAt": .string(format.string(from: line.expiresAt)),
                    "secondsLeft": .number(Double(max(0, Int(line.expiresAt.timeIntervalSince(now).rounded(.up))))),
                    "name": line.name.map(JSONValue.string) ?? .null]
        case let .joined(line, machine):
            return ["phase": .string("joined"), "joinTokenId": .string(line.joinTokenId),
                    "joined": .object(["id": .string(machine.id), "name": .string(machine.name), "state": .string(machine.state.rawValue)]),
                    "checks": .array(checks.map { .object(["step": .string($0.step.rawValue), "state": .string($0.state.rawValue),
                                                            "detail": .string($0.detail)]) })]
        }
    }
}

extension AddDeviceCard {
    /// A mint or a list read is one bundled CLI run (20 s at most) after the account's token.
    public nonisolated static let automationDeadline: Duration = .seconds(45)

    /// `device.join_line {open?, mint?, name?}`: Add Device's "Any machine" way. `open` (default true) opens
    /// the card on that way over `window` when it is not up (a card already up moves to it); `mint` presses
    /// Make Line (New Line after an expiry or a failure) with `name` and waits for the line. The reply:
    /// `shown`, `way`, `offersInvite` (signed in, the card shows Pair Another Machine, not the line), and the
    /// phase (``MachineJoinLineModel/Phase/automationJSON(checks:now:)``; `unavailable` with no join).
    public func automationJoinLine(_ params: [String: JSONValue], over window: NSWindow?) async -> JSONValue {
        if !isShown, params["open"]?.boolValue ?? true {
            await open(way: .joinLine, over: window).value
        } else if isShown, model.way != .joinLine {
            model.choose(.joinLine)
        }
        if params["mint"]?.boolValue == true, let join = model.joinLine, join.phase.mintsOnPress {
            if let name = params["name"]?.stringValue { join.name = name }
            await join.mint()
        }
        var reply: [String: JSONValue] = ["shown": .bool(isShown), "way": .string(model.way.rawValue), "offersInvite": .bool(model.offersInvite)]
        if let join = model.joinLine {
            reply.merge(join.phase.automationJSON(checks: join.checks, now: Date())) { $1 }
        } else {
            reply["phase"] = .string("unavailable")
        }
        return .object(reply)
    }
}
