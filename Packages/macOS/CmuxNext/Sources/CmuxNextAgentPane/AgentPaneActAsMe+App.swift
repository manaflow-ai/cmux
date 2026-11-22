#if DEBUG || CMUX_BENCH_HOOKS
public import CmuxNextControl
#endif
import CmuxNextDaemon
import CmuxNextSettings
import Foundation

/// "Computer use can act as me" in the app (``AgentPaneActAsMe``): where the person's grant is kept, the
/// managed profile that grants it on a provisioned Mac, and the consent card that asks.
extension AgentPaneActAsMe {
    /// The app's one grant (``PersonInputLedger/init(sources:)``). A signed build keeps the person's grant in
    /// this app's data-protection Keychain, which no other process writes; a DEV build without a Team ID
    /// keeps it for this launch only.
    static func app() -> AgentPaneActAsMe {
        let service = (Bundle.main.bundleIdentifier ?? "com.cmuxterm.app.next") + ".act-as-me"
        return AgentPaneActAsMe(store: CodeSigningTeam.current() == nil ? .memory() : .keychain(service: service))
    }

    /// Whether an administrator's profile forces `ComputerUseActsAsPerson` on in the managed domain. Read
    /// through CFPreferences in every build, never a DEBUG file override: only a forced value (an installed
    /// configuration profile) counts, never one `defaults write` sets.
    nonisolated static func managedForced(domain: String = ManagedPreferences.domain) -> Bool {
        let app = domain as CFString
        let key = managedKey as CFString
        CFPreferencesAppSynchronize(app)
        guard CFPreferencesAppValueIsForced(key, app) else { return false }
        return (CFPreferencesCopyAppValue(key, app) as? Bool) == true
    }

    @concurrent private static func readManaged() async -> Bool { managedForced() }

    /// Loads the stored grant and the managed profile (a profile installed or removed later applies at the
    /// next launch), and shows the consent card when asked. Ends with ``stop()`` (the ledger's).
    func start(check: PersonInputCheck) {
        guard following == nil else { return }
        var card: AgentPaneActAsMeCard?
        ask = { [weak self] in
            guard let self else { return }
            if card == nil {
                let made = AgentPaneActAsMeCard(grant: self)
                made.isPersonEvent = { check.isPerson($0) }
                card = made
            }
            card?.show()
        }
        hideCard = { card?.hide() }
        // task-owner: `following`, cancelled in stop(); one Keychain and one managed read at launch
        following = Task { [weak self] in
            await self?.load()
            let forced = await Self.readManaged()
            guard !Task.isCancelled else { return }
            self?.setManaged(forced)
        }
    }

    func stop() {
        following?.cancel()
        following = nil
    }
}

#if DEBUG || CMUX_BENCH_HOOKS
extension AgentPaneActAsMe {
    /// `debug.act_as_me {action}` (DEBUG and bench builds), for captures of the consent card: `ask` shows it as an
    /// agent's refused send would (whatever was asked before), `close` takes it away, `state` (default) reads the
    /// grant. It grants nothing: only the card's Allow, by the person's own click, turns the grant on.
    public func debugMethod() -> ControlMethod {
        .mainActor("debug.act_as_me") { [weak self] call in
            guard let self else { return .value(.null) }
            switch call.params["action"]?.stringValue ?? "state" {
            case "ask":
                guard let ask else { return .value(["error": "the grant was not started (no consent card)"]) }
                ask()
                return .value(["shown": true])
            case "close":
                hideCard?()
                return .value(["shown": false])
            default:
                return .value(["on": .bool(isOn), "asked": .bool(asked)])
            }
        }
    }
}
#endif
