// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import os

/// Machine-join consent. On a machine joined to a cmux team, the person at
/// the machine grants `screen` and `control` locally; acpmux keeps that
/// state and serves it as `_acpmux/machine_consent_get`.
///
/// The helper never reads that state itself: it asks the cmux app over the
/// host consent socket (a connection whose peer passed the cmux app check),
/// and the app asks its own acpmux daemon. Nothing the
/// helper's environment, endpoint.json or a socket request names can
/// redirect the question. Every answer is fetched fresh, and any failure
/// is "joined, nothing granted".

public enum ConsentSurface: String, Sendable, CaseIterable {
    case screen
    case control
}

/// What a tool call needs: observing needs `screen`, acting needs `screen`
/// and `control` (the rule acpmux's Computer Use bridge enforces).
public enum ConsentRequirement: Sendable, Equatable {
    case observe
    case act

    var surfaces: [ConsentSurface] {
        switch self {
        case .observe: [.screen]
        case .act: [.screen, .control]
        }
    }
}

public struct MachineConsentStatus: Sendable, Equatable {
    public var consentRequired: Bool
    public var screen: Bool
    public var control: Bool

    public init(consentRequired: Bool, screen: Bool, control: Bool) {
        self.consentRequired = consentRequired
        self.screen = screen
        self.control = control
    }

    /// No trusted answer: joined, nothing granted.
    public static let unavailable = MachineConsentStatus(consentRequired: true, screen: false, control: false)

    /// acpmux's `_acpmux/machine_consent_get` result, read strictly:
    /// `consentRequired` a JSON boolean and `consent.screen` and
    /// `consent.control` each "none" or "granted". Other fields (such as
    /// `lastRefusal`) are ignored. Anything else is nil.
    public init?(daemonResult data: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let required = Self.strictBool(object["consentRequired"]),
              let consent = object["consent"] as? [String: Any],
              let screen = Self.grant(consent["screen"]),
              let control = Self.grant(consent["control"]) else { return nil }
        self.init(consentRequired: required, screen: screen, control: control)
    }

    /// The `machine/consent` answer, exactly
    /// `{consentRequired, consent: {screen, control}}`.
    public var wire: Data {
        let body: [String: Any] = [
            "consentRequired": consentRequired,
            "consent": ["screen": screen ? "granted" : "none", "control": control ? "granted" : "none"],
        ]
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    /// The first surface `requirement` needs that this state does not grant.
    public func missing(for requirement: ConsentRequirement) -> ConsentSurface? {
        guard consentRequired else { return nil }
        return requirement.surfaces.first { surface in
            switch surface {
            case .screen: !screen
            case .control: !control
            }
        }
    }

    private static func strictBool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func grant(_ value: Any?) -> Bool? {
        switch value as? String {
        case "granted": true
        case "none": false
        default: nil
        }
    }
}

/// Where the helper learns consent. `current()` is asked on every call;
/// it never throws, and no answer is `.unavailable`.
public protocol MachineConsentAuthority: Sendable {
    func current() async -> MachineConsentStatus
    /// Records a refused call for the app's consent sheet. Best effort.
    func recordRefusal(surface: ConsentSurface, tool: String) async
    /// Why every answer is unavailable, when that is known (the host was
    /// not verified); nil otherwise, including a person's refusal.
    var refusalReason: ConsentRefusal.Reason? { get }
}

extension MachineConsentAuthority {
    public var refusalReason: ConsentRefusal.Reason? { nil }
}

/// No host to ask: every call that needs consent is refused.
public struct UnavailableConsent: MachineConsentAuthority {
    public init() {}
    public func current() async -> MachineConsentStatus { .unavailable }
    public func recordRefusal(surface: ConsentSurface, tool: String) async {}
}

/// Asks the cmux app over its verified host connection (`HostConsentServer`):
///   helper -> host: {"type":"machine_consent","id":N}
///   host -> helper: {"type":"machine_consent","id":N,"ok":true,"result":{...}}
///   helper -> host: {"type":"consent_refused","surface":S,"tool":T}
/// The host answers from its own acpmux daemon connection. With no verified
/// connection every answer is `.unavailable` and refusals say
/// `host_unverified`. A reply counts only on the connection that was asked;
/// no reply within `timeout` (below the bridge's 2 s), an error or a
/// malformed result is `.unavailable`. Nothing is cached.
public final class HostConsentChannel: MachineConsentAuthority {
    private struct State {
        var link: (id: UInt64, send: @Sendable (Data) -> Void)?
        var nextLink: UInt64 = 1
        var nextID = 1
        var pending: [Int: (link: UInt64, waiter: CheckedContinuation<Data?, Never>)] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let timeout: Duration

    public init(timeout: Duration = .milliseconds(1500)) {
        self.timeout = timeout
    }

    /// A verified host connection becomes the host; an earlier one's open
    /// questions fail closed. Returns the link to pass to `receive`/`detach`.
    func attach(_ send: @escaping @Sendable (Data) -> Void) -> UInt64 {
        let (link, dropped) = state.withLockUnchecked { state -> (UInt64, [CheckedContinuation<Data?, Never>]) in
            let link = state.nextLink
            state.nextLink += 1
            state.link = (link, send)
            return (link, Self.takePending(&state) { $0 != link })
        }
        for waiter in dropped { waiter.resume(returning: nil) }
        return link
    }

    /// The connection closed: it stops being the host, and its open
    /// questions fail closed.
    func detach(_ link: UInt64) {
        let dropped = state.withLockUnchecked { state -> [CheckedContinuation<Data?, Never>] in
            if state.link?.id == link { state.link = nil }
            return Self.takePending(&state) { $0 == link }
        }
        for waiter in dropped { waiter.resume(returning: nil) }
    }

    public var refusalReason: ConsentRefusal.Reason? {
        state.withLockUnchecked { $0.link == nil } ? .hostUnverified : nil
    }

    /// A reply on `link`. Unknown or late ids, and ids asked on another
    /// connection, are ignored.
    func receive(id: Int, result: Data?, link: UInt64) {
        let waiter = state.withLockUnchecked { state -> CheckedContinuation<Data?, Never>? in
            guard state.pending[id]?.link == link else { return nil }
            return state.pending.removeValue(forKey: id)?.waiter
        }
        waiter?.resume(returning: result)
    }

    public func current() async -> MachineConsentStatus {
        guard let data = await ask(), let status = MachineConsentStatus(daemonResult: data) else { return .unavailable }
        return status
    }

    public func recordRefusal(surface: ConsentSurface, tool: String) async {
        let send = state.withLockUnchecked { $0.link?.send }
        send?(HelperWire.line(["type": "consent_refused", "surface": surface.rawValue, "tool": tool]))
    }

    private func ask() async -> Data? {
        let timeout = self.timeout
        return await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            let request: (id: Int, send: @Sendable (Data) -> Void)? = state.withLockUnchecked { state in
                guard let link = state.link else { return nil }
                let id = state.nextID
                state.nextID += 1
                state.pending[id] = (link.id, continuation)
                return (id, link.send)
            }
            guard let request else { return continuation.resume(returning: nil) }
            // task-owner: one bounded deadline per question; it resumes the waiter only if no reply came first.
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.expire(request.id)
            }
            request.send(HelperWire.line(["type": "machine_consent", "id": request.id]))
        }
    }

    private func expire(_ id: Int) {
        let waiter = state.withLockUnchecked { $0.pending.removeValue(forKey: id)?.waiter }
        waiter?.resume(returning: nil)
    }

    private static func takePending(_ state: inout State, where matches: (UInt64) -> Bool)
        -> [CheckedContinuation<Data?, Never>] {
        let ids = state.pending.filter { matches($0.value.link) }.map(\.key)
        return ids.compactMap { state.pending.removeValue(forKey: $0)?.waiter }
    }
}

/// The refusal a gated call returns in place of running.
public struct ConsentRefusal: Error, Sendable, Equatable, CustomStringConvertible {
    public static let code = "consent_required"
    /// Set only when the refusal is not a person's choice.
    public enum Reason: String, Sendable, Equatable {
        case hostUnverified = "host_unverified"
    }

    public let surface: ConsentSurface
    public let tool: String
    public let reason: Reason?

    public init(surface: ConsentSurface, tool: String, reason: Reason? = nil) {
        self.surface = surface
        self.tool = tool
        self.reason = reason
    }

    public var description: String {
        if reason == .hostUnverified {
            return "\(Self.code) (\(Reason.hostUnverified.rawValue)): Computer Use is off: Computer Use could not verify "
                + "the cmux app that started it (a cmux build that isn't team-signed can't be verified). "
                + "`\(tool)` did not run. Use a signed cmux build."
        }
        return "\(Self.code): this machine is joined to a cmux team, and the person at it has not allowed "
            + "\(surface.rawValue) access. `\(tool)` did not run. Ask them to allow \(surface.rawValue) access on this machine."
    }
}

/// The consent check at the execution boundary. `admit` runs as the last
/// step before a tool executes, after every other await: it asks the
/// authority for the state as of now, and on a refusal records it and
/// throws, so nothing runs.
public final class ConsentGate: Sendable {
    /// Advertised in the socket's admission reply: every tool call passes
    /// the machine-consent gate at execution.
    public static let capability = "machine-consent-gate-v1"

    public let authority: any MachineConsentAuthority
    /// Names of tools whose `tools/list` entry is read-only (observe); every
    /// other name, including tools the inventory does not list, acts.
    private let readOnly = OSAllocatedUnfairLock<Set<String>?>(initialState: nil)

    public init(authority: any MachineConsentAuthority) {
        self.authority = authority
    }

    /// The requirement for `name`, from the driver's own inventory
    /// (`annotations.readOnlyHint`). Load it before asking for consent so
    /// no await follows the consent answer.
    public func requirement(for name: String, inventory: () async throws -> Data) async -> ConsentRequirement {
        if let known = readOnly.withLockUnchecked({ $0 }) {
            return known.contains(name) ? .observe : .act
        }
        guard let data = try? await inventory() else { return .act }
        let names = Self.readOnlyNames(data)
        readOnly.withLockUnchecked { $0 = names }
        return names.contains(name) ? .observe : .act
    }

    /// Throws `ConsentRefusal` unless consent allows `requirement` now.
    public func admit(_ name: String, requirement: ConsentRequirement) async throws {
        guard let surface = await authority.current().missing(for: requirement) else { return }
        await authority.recordRefusal(surface: surface, tool: name)
        throw ConsentRefusal(surface: surface, tool: name, reason: authority.refusalReason)
    }

    /// acpmux's bridge rule (cua_v2.rs `Helper::request`): the one entry
    /// with that name has `annotations.readOnlyHint` JSON `true`; a name
    /// listed twice is never read-only.
    static func readOnlyNames(_ inventory: Data) -> Set<String> {
        let object = try? JSONSerialization.jsonObject(with: inventory)
        let tools = (object as? [[String: Any]]) ?? ((object as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
        let listed = Dictionary(tools.compactMap { ($0["name"] as? String).map { ($0, 1) } }, uniquingKeysWith: +)
        return Set(tools.compactMap { tool in
            guard let name = tool["name"] as? String, listed[name] == 1,
                  let hint = (tool["annotations"] as? [String: Any])?["readOnlyHint"] as? NSNumber,
                  CFGetTypeID(hint) == CFBooleanGetTypeID(), hint.boolValue else { return nil }
            return name
        })
    }
}
