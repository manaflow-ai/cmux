// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The machine's Computer Use mode (docs/computer-use-approvals.md,
/// "Modes"), chosen by the person who owns the machine.
public enum ComputerUseMode: String, Sendable, CaseIterable {
    /// Each agent session starts upstream `bounded` with no app; a call on
    /// another app asks the person.
    case ask
    /// Upstream `standard`.
    case standard
    /// Upstream `bounded` with the owner's manifest.
    case bounded
    /// Upstream `unrestricted` (disposable VMs).
    case unrestricted

    /// The upstream mode an agent session runs in.
    var sessionMode: String {
        switch self {
        case .ask, .bounded: "bounded"
        case .standard: "standard"
        case .unrestricted: "unrestricted"
        }
    }
}

/// How the worker runs, fixed at launch from the environment the host set
/// when it started the worker. Nothing an agent sends on the socket can
/// change it: a mode change restarts the worker.
///
/// - `CMUX_COMPUTER_USE_MODE`: `ask` (default when unset), `standard`,
///   `bounded` or `unrestricted`. Any other value refuses to start.
/// - `CMUX_COMPUTER_USE_MANIFEST`: the owner's manifest (absolute path),
///   required for `bounded`.
/// - `unrestricted` also needs upstream's own two-part opt-in in the same
///   environment: `CUA_DRIVER_PERMISSION_MODE=unrestricted` and
///   `CUA_DRIVER_DANGEROUSLY_BYPASS_APPROVALS=1`.
/// - `CMUX_COMPUTER_USE_CLIENT` (else `CMUX_CUA_HOST_BUNDLE_ID`): the cmux
///   client the approval card names; `CMUX_COMPUTER_USE_MACHINE` (else the
///   host name): the machine it names.
public struct ComputerUseConfiguration: Sendable, Equatable {
    /// Session lifetime and idle limit (the ceiling and each session).
    public static let sessionLifetimeSeconds = 8 * 60 * 60
    public static let idleSeconds = 30 * 60

    public let mode: ComputerUseMode
    public let ownerManifestPath: String?
    public let client: String
    public let machine: String

    public enum ConfigurationError: Error, Equatable, CustomStringConvertible {
        case unknownMode(String)
        case boundedNeedsManifest
        case unrestrictedNotAcknowledged

        public var description: String {
            switch self {
            case .unknownMode(let value):
                "CMUX_COMPUTER_USE_MODE '\(value)' is not ask, standard, bounded or unrestricted"
            case .boundedNeedsManifest:
                "bounded mode needs CMUX_COMPUTER_USE_MANIFEST, an absolute path"
            case .unrestrictedNotAcknowledged:
                "unrestricted mode needs CUA_DRIVER_PERMISSION_MODE=unrestricted and "
                    + "CUA_DRIVER_DANGEROUSLY_BYPASS_APPROVALS=1 in the host's service configuration"
            }
        }
    }

    public init(mode: ComputerUseMode, ownerManifestPath: String? = nil, client: String, machine: String) {
        self.mode = mode
        self.ownerManifestPath = ownerManifestPath
        self.client = client
        self.machine = machine
    }

    public init(environment: [String: String]) throws {
        let raw = environment["CMUX_COMPUTER_USE_MODE"].map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let mode: ComputerUseMode
        if raw.isEmpty {
            mode = .ask
        } else if let parsed = ComputerUseMode(rawValue: raw) {
            mode = parsed
        } else {
            throw ConfigurationError.unknownMode(raw)
        }
        var manifest: String?
        if mode == .bounded {
            guard let path = environment["CMUX_COMPUTER_USE_MANIFEST"], path.hasPrefix("/") else {
                throw ConfigurationError.boundedNeedsManifest
            }
            manifest = path
        }
        if mode == .unrestricted {
            let flag = environment["CUA_DRIVER_DANGEROUSLY_BYPASS_APPROVALS"]?.lowercased() ?? ""
            guard environment["CUA_DRIVER_PERMISSION_MODE"] == "unrestricted",
                  ["1", "true", "yes", "on"].contains(flag) else {
                throw ConfigurationError.unrestrictedNotAcknowledged
            }
        }
        let client = environment["CMUX_COMPUTER_USE_CLIENT"].flatMap { $0.isEmpty ? nil : $0 }
            ?? environment["CMUX_CUA_HOST_BUNDLE_ID"].flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
        let machine = environment["CMUX_COMPUTER_USE_MACHINE"].flatMap { $0.isEmpty ? nil : $0 }
            ?? ProcessInfo.processInfo.hostName
        self.init(mode: mode, ownerManifestPath: manifest, client: client, machine: machine)
    }

    /// `cua_driver_create_v1` options: the immutable `authorization` ceiling.
    /// `allowed_modes` is the session mode alone; `ask` runs every session
    /// `bounded`. The compatibility context (calls outside a session, which
    /// the worker never makes) gets the same mode; under `bounded` upstream
    /// requires it a manifest, `compatibilityManifestPath`.
    func driverOptions(compatibilityManifestPath: String?) -> Data {
        var authorization: [String: Any] = [
            "allowed_modes": [mode.sessionMode],
            "compatibility_mode": mode.sessionMode,
            "unrestricted_acknowledged": mode == .unrestricted,
            "max_session_ttl_seconds": Self.sessionLifetimeSeconds,
            "max_idle_ttl_seconds": Self.idleSeconds,
        ]
        if let compatibilityManifestPath {
            authorization["compatibility_capability_manifest_path"] = compatibilityManifestPath
        }
        return (try? CanonicalJSON.encode(["authorization": authorization])) ?? Data("{}".utf8)
    }

    /// `cua_driver_session_create_v1` options for one session handle.
    func sessionOptions(publicSession: String, lifetimeSeconds: Int, manifestPath: String?) -> Data {
        let lifetime = max(1, min(lifetimeSeconds, Self.sessionLifetimeSeconds))
        var options: [String: Any] = [
            "public_session": publicSession,
            "mode": mode.sessionMode,
            "ttl_seconds": lifetime,
            "idle_ttl_seconds": min(Self.idleSeconds, lifetime),
        ]
        if let manifestPath { options["capability_manifest_path"] = manifestPath }
        return (try? CanonicalJSON.encode(options)) ?? Data("{}".utf8)
    }
}
