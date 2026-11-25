import Foundation
import Testing
@testable import CmuxMobileModel

/// Settings → Transport → Tailscale only (PROTOCOL.md "Tailscale-only links"): the choice,
/// its fallback switch and what a Mac's view says when Tailscale can't carry the dial.
@Suite struct TailscaleOnlyTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func defaults() -> UserDefaults {
        let name = "tailscale-only-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @MainActor @Test func theChoiceAndItsFallbackPersistAndDefaultOff() {
        let store = defaults()
        let settings = SettingsStore(defaults: store)
        #expect(settings.transport == .wireguard)
        #expect(settings.tailscaleFallback == false)
        settings.transport = .tailscale
        settings.tailscaleFallback = true
        let again = SettingsStore(defaults: store)
        #expect(again.transport == .tailscale)
        #expect(again.tailscaleFallback)
        // The dial reads the fallback through this key (`TailscaleOnly.fallbackKey`).
        #expect(store.bool(forKey: "cmuxMobile.settings.tailscaleFallback"))
    }

    @Test func thePickerNamesItAndTheDeveloperRelayDoesNotApply() {
        #expect(TransportKind.allCases == [.wireguard, .webrtc, .tailscale])
        #expect(TransportKind.tailscale.pickerTitle == "Tailscale only")
        #expect(TransportKind.tailscale.pickerDetail != nil)
        #expect(TransportKind.wireguard.pickerDetail == nil)
        #expect(TransportKind.tailscale.settingsValue(blockUDP: true, relayOnly: true) == "Tailscale only")
    }

    @Test func eachTailscaleProblemHasItsOwnWordsAndRetry() {
        let mac = MacDevice(id: "m", name: "Studio", isOnline: true, lastSeenAt: nil)
        let problems: [TailscaleProblem] = [.phoneOff, .macOff, .unreachable, .noAnswer, .unsupported]
        var titles = Set<String>()
        for problem in problems {
            let reach = MacReachability.resolve(mac: mac, connection: .failed("Offline"), failure: .tailscale(problem), live: true)
            #expect(reach == .tailscale(problem))
            #expect(reach.offersRetry)
            #expect(!reach.message(macName: "Studio", now: now).isEmpty)
            titles.insert(reach.title(macName: "Studio"))
        }
        #expect(titles.count == problems.count)
        let off = MacReachability.tailscale(.phoneOff)
        #expect(off.title(macName: "Studio") == "Tailscale isn't connected on this iPhone")
        #expect(off.message(macName: "Studio", now: now).contains("Fall back to WireGuard"))
    }

    @Test func aNewDialOrALiveLinkWinsOverAnOldTailscaleProblem() {
        let mac = MacDevice(id: "m", name: "Studio", isOnline: true, lastSeenAt: nil)
        #expect(MacReachability.resolve(mac: mac, connection: .connecting, failure: .tailscale(.macOff), live: true) == .connecting)
        #expect(MacReachability.resolve(mac: mac, connection: .connected, failure: .tailscale(.macOff), live: true) == .connected)
    }

    @Test func aTailscaleFailureStopsARecoveryAttemptAtTheMacStep() {
        let attempt = MacRecoveryAttempt(step: .mac)
        let next = attempt.advanced(by: .failed(.tailscale(.phoneOff)))
        #expect(next.result == .failed(.mac))
        #expect(next.action == .retry)
    }

    @Test func eachTailscaleProblemHasAShortStatusThatFitsTheHeader() {
        let problems: [TailscaleProblem] = [.phoneOff, .macOff, .unreachable, .noAnswer, .unsupported]
        for problem in problems {
            let status = MacReachability.tailscale(problem).shortStatus
            #expect(!status.isEmpty)
            #expect(status.count <= 22)
        }
    }
}
