public import Foundation

/// What a `cloud.startChat` start does about its machine's harness login, and why (the App's
/// `CloudStartChat+Login`). A start that passes no login leaves Claude there signed out or on a
/// rejected login, and every turn then fails with the bare "The provider rejected Claude Code's
/// credentials on this Cloud machine" card. So the start logs this decision and keeps it on the machine's
/// `cloud.machines` row (`harness_login`), never a silent skip.
public nonisolated struct CloudHarnessLoginDecision: Sendable, Equatable {
    public enum Step: String, Sendable, Equatable { case skip, install, confirmThenInstall = "confirm-then-install" }

    public enum Reason: String, Sendable, Equatable {
        /// This build passes no login (``CloudCredentialTransfer/passesHarnessLogin(isDogfoodBuild:setting:)``).
        case buildGateOff = "build-gate-off"
        /// The chat's harness has no transfer here (Codex keeps its broker flow, pi and opencode none).
        case noTransfer = "no-transfer-for-harness"
        case signedOut = "signed-out"
        /// The platform does not say the signed-in caller owns the machine.
        case callerNotOwner = "caller-not-owner"
        /// The guest's `/etc/cmux/vm-kind` is neither `owner` nor `team` (missing or unknown).
        case guestNotOwner = "guest-not-owner"
        /// The guest's kind could not be read (the exec failed).
        case guestUnread = "guest-kind-unread"
        /// The machine's own login stays (``CloudMachineLogin/needsLogin`` is false).
        case machineLoginKept = "machine-login-kept"
        case installCached = "install-cached"
        case confirmFirst = "confirm-first"
    }

    public var gate: Bool
    public var provider: CloudCredentialTransfer.Provider?
    public var signedIn: Bool
    /// Nil when not asked (an earlier check decided).
    public var callerOwns: Bool?
    /// The guest's `/etc/cmux/vm-kind` ("" when missing); nil when not read or the read failed.
    public var guestKind: String?
    public var machineLogin: CloudMachineLogin?
    public var cached: Bool
    /// What came of it once decided: "installed", "declined" (the confirm), or the transfer's fixed failure text.
    public var outcome: String?
    public var step: Step { Self.decide(self).0 }
    public var reason: Reason { Self.decide(self).1 }

    public init(gate: Bool, provider: CloudCredentialTransfer.Provider?, signedIn: Bool, callerOwns: Bool? = nil,
                guestKind: String? = nil, machineLogin: CloudMachineLogin? = nil, cached: Bool = false) {
        (self.gate, self.provider, self.signedIn, self.callerOwns) = (gate, provider, signedIn, callerOwns)
        (self.guestKind, self.machineLogin, self.cached) = (guestKind, machineLogin, cached)
    }

    /// The start passed no personal login because the machine is a team machine (guest kind `team`):
    /// the chat's sign-in card says so and offers no login transfer (handshake `cloudTeamMachine`).
    /// The creator's own machine takes the login whatever its guest kind (``guestTakesLogin``), so
    /// this no longer happens; kept for the handshake.
    public var skippedTeamMachine: Bool { reason == .guestNotOwner && guestKind == "team" }

    /// Whether the guest takes the caller's login: an `owner` guest, or a `team` one, since the
    /// creator is the machine's owner team or no team (Leo, 2026-11-01: "team or no team the thing
    /// should just work / you shouldn't be blocked by stuff if you bought the access to a machine /
    /// it's your machine"). Reached only once ``readsMachine`` (the platform says the caller owns
    /// it); a teammate who did not create the machine never gets here, so a shared machine keeps
    /// each guest on their own login.
    public var guestTakesLogin: Bool { guestKind == "owner" || guestKind == "team" }

    /// Whether the start reads the guest and its login: only once the earlier checks let it go on.
    public var readsMachine: Bool { gate && provider == .claude && signedIn && callerOwns == true }

    private static func decide(_ d: Self) -> (Step, Reason) {
        // Codex logins are per machine (its refresh token is VM-bound): its broker flow stays the turn card's.
        guard d.gate else { return (.skip, .buildGateOff) }
        guard d.provider == .claude else { return (.skip, .noTransfer) }
        guard d.signedIn else { return (.skip, .signedOut) }
        guard d.callerOwns == true else { return (.skip, .callerNotOwner) }
        guard let kind = d.guestKind else { return (.skip, .guestUnread) }
        // The caller created the machine (``callerOwns``): an owner or team guest takes the login
        // (the transfer runs its creator allowance on a team guest, ``CloudCredentialInstaller``).
        guard kind == "owner" || kind == "team" else { return (.skip, .guestNotOwner) }
        guard d.machineLogin?.needsLogin ?? true else { return (.skip, .machineLoginKept) }
        return d.cached ? (.install, .installCached) : (.confirmThenInstall, .confirmFirst)
    }

    /// One line for the log and the `cloud.machines` row; no token, path or provider output.
    public var summary: String {
        func word(_ value: Bool?) -> String { value.map { $0 ? "yes" : "no" } ?? "-" }
        let kind = guestKind.map { $0.isEmpty ? "(none)" : $0 } ?? "-"
        return "\(step.rawValue) (\(reason.rawValue)): gate \(gate ? "on" : "off"), provider \(provider?.rawValue ?? "-"), "
            + "signed in \(word(signedIn)), caller owns \(word(callerOwns)), guest \(kind), "
            + "machine login \(machineLogin?.rawValue ?? "-"), cached \(word(cached))" + (outcome.map { " -> \($0)" } ?? "")
    }

    /// Prints the guest's kind after a fixed marker, so an exec that ran is told from one that failed.
    public static let guestKindProbe = #"printf 'vm-kind:%s\n' "$(head -c 64 /etc/cmux/vm-kind 2>/dev/null | tr -d '[:space:]')""#

    /// The kind ``guestKindProbe`` printed ("" when the guest has none), or nil for output without the marker.
    public static func guestKind(stdout: String) -> String? {
        stdout.split(separator: "\n").lazy.compactMap { line in
            line.hasPrefix("vm-kind:") ? String(line.dropFirst("vm-kind:".count)).trimmingCharacters(in: .whitespaces) : nil
        }.first
    }
}
