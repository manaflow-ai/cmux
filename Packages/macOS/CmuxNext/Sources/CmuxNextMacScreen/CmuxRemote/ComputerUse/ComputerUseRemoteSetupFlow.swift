import CmuxNextCompat
public import Observation
import os

nonisolated private let remoteSetupLogger = Logger(subsystem: "com.cmuxterm.app.next", category: "computer-use")

/// One of cmux Remote's two macOS grants.
public nonisolated enum ComputerUseRemoteGrant: String, Sendable, Equatable {
    case accessibility
    case screenRecording
}

/// What Computer Use setup knows of cmux Remote's grants.
public nonisolated enum ComputerUseRemoteSetupState: Sendable, Equatable {
    /// The grants are not cmux Remote's (the legacy helper, the helper v2 on its own).
    case notRemote
    /// Computer Use is off, turned off by policy, or cannot run: nothing to set up.
    case inactive
    /// cmux Remote's grants are being read, or unknown for now (no answer yet).
    case reading
    /// cmux Remote answered.
    case granted(accessibility: Bool, screenRecording: Bool)
}

/// Computer Use setup as the flow reads and drives it (the App's `ComputerUseSetup`).
@MainActor
public protocol ComputerUseRemoteGrantSource: AnyObject {
    /// Read inside an observation: a change of it updates the flow.
    var remoteSetupState: ComputerUseRemoteSetupState { get }
    /// Asks macOS for `grant` in cmux Remote (the person's press only).
    func requestRemoteGrant(_ grant: ComputerUseRemoteGrant)
    /// Opens the System Settings pane of `grant` (the person's press only).
    func openRemoteGrantSettings(_ grant: ComputerUseRemoteGrant)
}

/// A joined Mac's team consent (Settings > Devices, Screen sharing and Control): while either is off,
/// acpmux refuses every Computer Use call with `consent_required`. The app gives `JoinConsentModel`'s.
public nonisolated struct ComputerUseTeamConsent: Sendable {
    /// This Mac is joined and a switch is off; read inside an observation.
    public var needed: @MainActor @Sendable () -> Bool
    /// Turns on what is off through the switches' person path (Touch ID or the login password each).
    public var request: @MainActor @Sendable () -> Void

    public init(needed: @escaping @MainActor @Sendable () -> Bool, request: @escaping @MainActor @Sendable () -> Void) {
        self.needed = needed
        self.request = request
    }

    /// Not joined, or no join consent on this platform.
    public static let none = ComputerUseTeamConsent(needed: { false }, request: {})
}

/// Computer Use setup when Computer Use runs in cmux Remote (driver upstream, the default).
/// cmux Remote holds Accessibility and Screen Recording, and only a request in cmux Remote makes
/// macOS ask for them, so turning Computer Use on (Settings, the palette, `cmux settings set
/// --confirm`, `cmux setup computer-use`) or launching with it on shows the setup card while a
/// grant is off. Every entrypoint turns the one setting on, and this follows the setup's state,
/// so all of them get it.
///
/// Continue asks macOS for Accessibility first and, once it is on, for Screen Recording, one
/// request each (cmux Remote opens the System Settings pane when macOS will not prompt again).
/// The grants are read again on the setup's existing events only (the app becoming active,
/// macOS's Accessibility change). When both are on, the card closes and the flow is ready. Not
/// Now (or Close) stops asking until Computer Use is turned off and on, or the app starts again;
/// an agent's computer use call still asks through its own card then.
///
/// Nothing here grants anything: each request follows a person's press on the card, and macOS
/// asks the person again.
@MainActor
@Observable
public final class ComputerUseRemoteSetupFlow {
    public nonisolated enum Step: Equatable, Sendable {
        /// Not cmux Remote's grants, or Computer Use is off: nothing to do here.
        case none
        /// cmux Remote's grants are being read.
        case reading
        /// A grant is off: the card names both and waits for Continue.
        case ask
        /// After Continue: the grant to ask macOS for now.
        case request(ComputerUseRemoteGrant)
        /// Both are on, but this Mac is joined to a team whose consent is off: the card asks to
        /// turn on Screen sharing and Control, saying it lets the team's machines in too.
        case team
        /// Both are on (and the team consent, on a joined Mac).
        case ready
    }

    public private(set) var step: Step = .none
    @ObservationIgnored private let source: any ComputerUseRemoteGrantSource
    @ObservationIgnored private let presenter: any ComputerUseRemoteSetupPresenting
    @ObservationIgnored private let team: ComputerUseTeamConsent
    @ObservationIgnored private var continued = false
    @ObservationIgnored private var dismissed = false
    /// Setup reached ready since Computer Use turned on: a team consent turned off after that is the
    /// person's own revoke (Settings > Devices), so the team card does not come back for it.
    @ObservationIgnored private var reachedReady = false
    @ObservationIgnored private var requested: Set<String> = []
    @ObservationIgnored private var following: Task<Void, Never>?

    public init(source: any ComputerUseRemoteGrantSource, presenter: any ComputerUseRemoteSetupPresenting, team: ComputerUseTeamConsent = .none) {
        self.source = source
        self.presenter = presenter
        self.team = team
    }

    // cx-t7hu: not an isolated deinit; the handle stops from any thread.
    nonisolated deinit { following?.cancel() }

    /// What to do for `state` now.
    public nonisolated static func step(_ state: ComputerUseRemoteSetupState, continued: Bool, teamConsentNeeded: Bool = false) -> Step {
        switch state {
        case .notRemote, .inactive: return .none
        case .reading: return .reading
        case .granted(true, true): return teamConsentNeeded ? .team : .ready
        case .granted(let accessibility, _):
            guard continued else { return .ask }
            return .request(accessibility ? .screenRecording : .accessibility)
        }
    }

    /// Follows the setup for the app's life. Idempotent.
    public func start() {
        guard following == nil else { return }
        let source = source, team = team
        update()
        // task-owner: follows the setup's grants for the app's life; deinit cancels it.
        following = Task { [weak self] in
            for await _ in ObservationStream({ Observed(state: source.remoteSetupState, team: team.needed()) }) { self?.update() }
        }
    }

    private func update() {
        let next = Self.step(source.remoteSetupState, continued: continued, teamConsentNeeded: team.needed())
        let previous = step
        if next != previous { step = next }
        switch next {
        case .none:
            // Off (or not cmux Remote): the next turn-on asks again.
            (continued, dismissed, requested, reachedReady) = (false, false, [], false)
            presenter.withdrawSetup()
        case .reading:
            break
        case .ready:
            (continued, requested, reachedReady) = (false, [], true)
            presenter.withdrawSetup()
            if previous != .ready { remoteSetupLogger.notice("Computer Use: cmux Remote has Accessibility and Screen Recording") }
        case .ask:
            guard !dismissed else { return presenter.withdrawSetup() }
            show(.ask)
        case .team:
            guard !dismissed, !reachedReady else { return presenter.withdrawSetup() }
            show(.teamConsent)
        case .request(let grant):
            guard !dismissed else { return presenter.withdrawSetup() }
            show(grant == .accessibility ? .accessibility : .screenRecording)
            // One request per grant: a refresh never asks macOS again.
            if requested.insert(grant.rawValue).inserted { source.requestRemoteGrant(grant) }
        }
    }

    /// What the flow follows: the grants and the team consent.
    private nonisolated struct Observed: Sendable, Equatable {
        var state: ComputerUseRemoteSetupState
        var team: Bool
    }

    private func show(_ card: ComputerUseRemoteSetupCard) {
        presenter.showSetup(card) { [weak self] button in self?.pressed(button) }
    }

    /// The person's press on the card.
    private func pressed(_ button: String) {
        switch button {
        case ComputerUseRemoteSetupCard.continueButton: continued = true
        case ComputerUseRemoteSetupCard.openSettingsButton:
            if case .request(let grant) = step { source.openRemoteGrantSettings(grant) }
        case ComputerUseRemoteSetupCard.turnOnTeamButton:
            // The card stays up until the consent reads on, so a Touch ID cancel can be retried.
            if step == .team { team.request() }
            return
        default: dismissed = true // Not Now, Close.
        }
        update()
    }
}
