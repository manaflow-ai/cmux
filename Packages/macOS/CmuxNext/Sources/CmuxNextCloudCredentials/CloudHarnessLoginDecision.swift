public import CmuxNextCloud
public import Foundation

/// What a `cloud.startChat` start does about its machine's harness login, and why (the App's
/// `CloudStartChat+Login`). A start that passes no login leaves Claude there signed out or on a
/// rejected login, and every turn then fails with the bare "The provider rejected Claude Code's
/// credentials on this Cloud machine" card. So the start logs this decision and keeps it on the machine's
/// `cloud.machines` row (`harness_login`), never a silent skip.
///
/// The rules are Rust's (cmux-tui/crates/cmux-cloud-start-core `harness_login`, with their tests),
/// asked in one app FFI call (`cloud_harness_login`) that reads the raw facts this type holds: the
/// build and its setting, the chat's harness, the guest probe's output and the machine login probe's
/// output. So an FFI that does not answer is the one failure, recorded as ``Reason/ffiFailed``, never
/// an ordinary skip reason (cmux#32416).
public nonisolated struct CloudHarnessLoginDecision: Sendable, Equatable {
    public enum Step: String, Sendable, Equatable, Decodable {
        case skip, install, confirmThenInstall = "confirm-then-install"
        /// A Release build's one-time consent before the first copy (``CloudLoginCopyConsentSetting``).
        case askConsent = "ask-consent"
        /// A run that may show no prompt (`cmux cloud start-session`) where one would be needed: it fails at once.
        case refuse
    }

    /// The person's login choice (`cmux cloud start-session --login`, or the one kept per user).
    public enum Choice: String, Sendable, Equatable, Codable, CaseIterable {
        /// Give the machine the person's own login.
        case pass
        /// Use the machine's own login; refuse when it has none.
        case machine
        /// Pass nothing.
        case none
    }

    /// The rules' reasons (cmux-cloud-start-core `Reason`), plus ``ffiFailed`` when the FFI did not answer.
    public enum Reason: String, Sendable, Equatable, Decodable {
        case buildGateOff = "build-gate-off"
        case noTransfer = "no-transfer-for-harness"
        /// Codex: the Mac's broker gives the machine short-lived access before the first prompt (cmux#33489).
        case codexBroker = "codex-broker"
        case signedOut = "signed-out"
        case callerNotOwner = "caller-not-owner"
        case guestNotOwner = "guest-not-owner"
        case guestUnread = "guest-kind-unread"
        case machineLoginKept = "machine-login-kept"
        case installCached = "install-cached"
        case confirmFirst = "confirm-first"
        /// The consent (Release) or the person's own choice stands in for the confirm.
        case installChosen = "install-chosen"
        /// Release: the remote switch is off, or was not read; the machine offers its own sign-in.
        case remoteSwitchOff = "remote-switch-off"
        /// Release: the one-time consent has not been answered yet.
        case consentFirst = "consent-first"
        /// Release: the person said no, or took it back in Settings.
        case consentDeclined = "consent-declined"
        /// The app FFI gave no answer: the start passes no login (never a silent one: the record says so).
        case choseNone = "chose-none"
        case machineLoginMissing = "machine-login-missing"
        case needsLoginChoice = "needs-login-choice"
        case ffiFailed = "ffi-failed"
    }

    /// What the machine's login probe answered (``CloudMachineLogin/probe(cachedFingerprint:endpoint:)``).
    public struct MachineProbe: Sendable, Equatable, Encodable {
        public var exitCode: Int
        public var stdout: String

        public init(exitCode: Int, stdout: String) {
            (self.exitCode, self.stdout) = (exitCode, stdout)
        }
    }

    /// A DEV or dogfood build (the app passes `DevTools.isEnabled`).
    public var dogfood: Bool
    /// The `cmux.cloud.passHarnessLogin` setting; nil when unset.
    public var setting: Bool?
    /// The chat's harness; nil for none named (the app's default agent, Claude).
    public var harness: String?
    public var signedIn: Bool
    /// Nil when not asked (an earlier check decided).
    public var callerOwns: Bool?
    /// The guest probe's stdout (``Verdict/guestKindProbe``); nil when not run or the exec failed.
    public var guestStdout: String?
    /// The machine login probe's answer; nil when not run.
    public var machineProbe: MachineProbe?
    /// The machine's login when known without the probe (an exec that failed reads as `.none`).
    public var machineLogin: CloudMachineLogin?
    public var cached: Bool
    /// Release: the person's answer to the one-time consent; nil when never asked.
    public var consent: Bool?
    /// Release: the remote switch's fresh answer (``CloudHarnessLoginCopySwitch``); nil when not read.
    public var remoteSwitch: Bool?
    /// What came of it once decided: "installed", "declined" (the confirm), or the transfer's fixed failure text.
    public var outcome: String?
    /// The run's `--login`; nil when not given.
    public var requested: Choice?
    /// Whether `requested` is the person's own (only the person's `pass` stands in for the confirm).
    public var requestedByPerson = false
    /// The choice the person made before (``CloudHarnessLoginChoices``); nil when none.
    public var stored: Choice?
    /// A run that may show no prompt (`cmux cloud start-session`): it refuses where it would ask.
    public var headless = false

    public init(dogfood: Bool, setting: Bool?, harness: String?, signedIn: Bool) {
        (self.dogfood, self.setting, self.harness, self.signedIn) = (dogfood, setting, harness, signedIn)
        cached = false
    }

    /// Takes ``CloudMachineLogin/read(on:machineID:teamID:userID:)``'s answer: an exec that failed reads
    /// as `.none`, as the probe before it did.
    public mutating func take(_ read: (probe: MachineProbe?, cached: Bool)) {
        (machineProbe, machineLogin, cached) = (read.probe, read.probe == nil ? CloudMachineLogin.none : nil, read.cached)
    }

    /// The rules' answer for these inputs, with the facts resolved.
    public struct Verdict: Sendable, Equatable, Decodable {
        public var step: Step
        public var reason: Reason
        public var gate: Bool
        public var provider: String?
        public var guestKind: String?
        public var machineLogin: CloudMachineLogin?
        public var guestKindProbe: String
        public var readsMachine: Bool
        public var guestTakesLogin: Bool
        public var skippedTeamMachine: Bool
        public var summary: String

        /// ``provider`` as a transfer provider; nil for a harness with no transfer (pi, opencode).
        public var transferProvider: CloudCredentialTransfer.Provider? { provider.flatMap(CloudCredentialTransfer.Provider.init(rawValue:)) }
    }

    private struct Request: Encodable {
        var dogfood: Bool, setting: Bool?, harness: String, signedIn: Bool, callerOwns: Bool?, guestStdout: String?
        var machineProbe: MachineProbe?, machineLogin: String?, cached: Bool, outcome: String?
        var consent: Bool?, remoteSwitch: Bool?
        var requested: Choice?, requestedByPerson: Bool, stored: Choice?, headless: Bool
    }

    /// Asks the rules once; read every field off the one answer.
    public var verdict: Verdict {
        // "" is no harness named: the rules read it as the default agent, Claude.
        let request = Request(dogfood: dogfood, setting: setting, harness: harness ?? "", signedIn: signedIn, callerOwns: callerOwns,
                              guestStdout: guestStdout, machineProbe: machineProbe, machineLogin: machineLogin?.rawValue,
                              cached: cached, outcome: outcome, consent: consent, remoteSwitch: remoteSwitch,
                              requested: requested, requestedByPerson: requestedByPerson, stored: stored, headless: headless)
        return CloudStartCore().call("cloud_harness_login", request, as: Verdict.self) ?? Verdict(
            step: .skip, reason: .ffiFailed, gate: false, provider: nil, guestKind: nil, machineLogin: nil, guestKindProbe: "",
            readsMachine: false, guestTakesLogin: false, skippedTeamMachine: false,
            summary: "skip (ffi-failed)" + (outcome.map { " -> \($0)" } ?? ""))
    }

    public var step: Step { verdict.step }
    /// Why a run that may show no prompt fails at once (``Step/refuse``); nil when it goes on. A
    /// headless Codex start with no choice goes on as on base (its broker or the machine's own login).
    public var refusal: Reason? { verdict.step == .refuse ? verdict.reason : nil }
    public var reason: Reason { verdict.reason }
    /// Whether this build passes a login: DEV and dogfood builds unless the setting turns it off; a
    /// Release build only while the remote switch is on (its consent is asked after).
    public var gate: Bool { verdict.gate }
    /// The provider whose login the start passes; nil for a harness with no transfer (pi, opencode).
    public var provider: CloudCredentialTransfer.Provider? { verdict.transferProvider }
    /// The guest's `/etc/cmux/vm-kind` as read ("" when missing); nil when not read.
    public var guestKind: String? { verdict.guestKind }
    /// The start passed no personal login because the machine is a team machine (handshake `cloudTeamMachine`).
    public var skippedTeamMachine: Bool { verdict.skippedTeamMachine }
    /// Whether the guest takes the caller's login (an `owner` or `team` guest of the caller's own machine).
    public var guestTakesLogin: Bool { verdict.guestTakesLogin }
    /// Whether the start reads the guest and its login: only once the earlier checks let it go on.
    public var readsMachine: Bool { verdict.readsMachine }
    /// One line for the log and the `cloud.machines` row; no token, path or provider output.
    public var summary: String { verdict.summary }

    /// Reads the guest's kind (``Verdict/guestKindProbe``, through `exec`; nil when the exec failed), again while a
    /// new machine's guest has none yet: its cmux-host writes /etc/cmux/vm-kind only once it binds. The transfer's
    /// budget and spacing (``CloudCredentialTransfer/guestCheckTries``). A failed exec or any recorded kind ends it;
    /// every exec and pause counts against `budget`, slow ones included, and a read cut off by it keeps the last answer.
    public mutating func readGuest(exec: @escaping @Sendable (String) async -> String?, pause: @escaping @Sendable () async throws -> Void,
                                   budget: Duration = CloudCredentialTransfer.guestCheckBudget) async throws {
        let deadline = ContinuousClock.now + budget, probe = verdict.guestKindProbe
        for attempt in 1...CloudCredentialTransfer.guestCheckTries {
            guard let read = try await CloudCredentialTransfer.before(deadline, { await exec(probe) }) else { return }
            guestStdout = read
            guard guestKind == "", attempt < CloudCredentialTransfer.guestCheckTries,
                  try await CloudCredentialTransfer.before(deadline, pause) != nil else { return }
        }
    }
}
