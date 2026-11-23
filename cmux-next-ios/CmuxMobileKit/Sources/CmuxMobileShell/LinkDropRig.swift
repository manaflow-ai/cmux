#if os(iOS) && DEBUG
import CmuxMobileChief
import CmuxMobileDesign
import CmuxMobileModel
import Foundation
import Observation
import SwiftUI

/// The offline link-drop rig (DEBUG, mock mode): a Mac's link goes down and comes back on a
/// script, with no agent and no Mac, so every connection chip surface can be timed in the
/// simulator (`LinkDropChipUITests`): how long after the drop its chip shows, and whether
/// anything on screen moved, idle and under load.
///
/// Mock mode builds no `LiveCoordinator`, so the rig does what the coordinator does on a drop:
/// it records the Mac's drop (`AppStore.macLinkDownSince`, as `updateTerminalsOffline` does),
/// marks the Mac's link failed (`macConnection`, what Home reads), and holds the Workspaces
/// banner for the quiet bound (`HeldNotice`, as `phaseChanged` holds "Reconnecting"). On the
/// return it clears all three.
///
/// Launch arguments:
/// - `-cmux-mobile-link-drop home|workspaces`: the surface (its tab), and turns the rig on.
/// - `-cmux-mobile-link-drop-cycles N` (2): drops in a row.
/// - `-cmux-mobile-link-drop-down S` (14): seconds each drop lasts (past the 10 s bound).
/// - `-cmux-mobile-link-drop-up S` (5): seconds up before each drop, and after the last return.
/// - `-cmux-mobile-link-drop-load 1`: under load: 10,000 kept rows, the main thread busy 6 ms
///   of every 16 ms, and two background threads busy (`LinkDropLoad`).
///
/// Each drop and return is stamped (wall clock, ms) in the value of the invisible
/// `rig.linkdrop` element (``LinkDropMarker``), which the UI test reads; the simulator and
/// the test runner share the host's clock.
@MainActor
@Observable
final class LinkDropRig {
    static let shared = LinkDropRig()

    /// The Mac the rig drops; nil while the rig is off.
    private(set) var macID: String?
    /// The Workspaces banner, as the coordinator's held slot would show it.
    private(set) var banner: ConnectionBannerState?
    /// Every event so far, `down1=… back1=… … done`, wall clock in ms.
    private(set) var marker = "off"

    @ObservationIgnored private lazy var bannerHold = HeldNotice<ConnectionBannerState> { [weak self] in
        self?.banner = $0
    }

    static let macName = "Demo Mac 1"

    func runIfConfigured(shell: ShellModel) async {
        let defaults = UserDefaults.standard
        guard let surface = defaults.string(forKey: "cmux-mobile-link-drop") else { return }
        let loaded = defaults.bool(forKey: "cmux-mobile-link-drop-load")
        // A launch argument's value arrives as a string.
        func number(_ key: String, _ fallback: Double) -> Double {
            defaults.string(forKey: "cmux-mobile-link-drop-\(key)").flatMap(Double.init) ?? fallback
        }
        let cycles = max(1, Int(number("cycles", 2)))
        let down = number("down", 14)
        let up = number("up", 5)
        let mac = "mac-studio"
        let store = shell.store

        // A connected Mac with kept rows (Home) and its workspaces (Workspaces).
        MacHomeFeed.shared.seedStressRows(count: loaded ? 10_000 : 8, macID: mac)
        store.tracksMacData = true
        store.macConnection[mac] = .connected
        macID = mac
        shell.tab = surface == "workspaces" ? .workspaces : .home
        if loaded { LinkDropLoad.start() }
        marker = loaded ? "load=1 up" : "load=0 up"

        for cycle in 1 ... cycles {
            try? await Task.sleep(for: .seconds(up))
            // The drop.
            store.macLinkDownSince[mac] = Date()
            store.macConnection[mac] = .failed("Can't reach the Mac right now.")
            bannerHold.hold(.reconnecting(to: Self.macName, identity: mac), for: QuietStatusGate.threshold)
            stamp("down\(cycle)")
            try? await Task.sleep(for: .seconds(down))
            // The return.
            store.macLinkDownSince[mac] = nil
            store.macConnection[mac] = .connected
            bannerHold.show(nil)
            stamp("back\(cycle)")
        }
        try? await Task.sleep(for: .seconds(up))
        marker += " done"
    }

    private func stamp(_ event: String) {
        marker += String(format: " %@=%.0f", event, Date().timeIntervalSince1970 * 1000)
    }
}

/// The rig's events for the UI test: an invisible 1 pt element over the corner, laid over
/// everything (an overlay moves nothing), only while the rig runs.
struct LinkDropMarker: View {
    let rig = LinkDropRig.shared

    var body: some View {
        if rig.macID != nil {
            Color.clear
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .accessibilityElement()
                .accessibilityLabel(Text(verbatim: "link drop rig"))
                .accessibilityValue(Text(verbatim: rig.marker))
                .accessibilityIdentifier("rig.linkdrop")
        }
    }
}

/// The rig's load: the main thread busy 6 ms of every 16 ms (a frame's worth of work the app
/// did not plan), and two background threads busy 10 ms of every 12 ms (a busy phone).
enum LinkDropLoad {
    @MainActor private static var timer: Timer?

    @MainActor static func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { _ in spin(0.006) }
        for index in 0 ..< 2 {
            let thread = Thread {
                while true {
                    spin(0.010)
                    Thread.sleep(forTimeInterval: 0.002)
                }
            }
            thread.name = "link-drop-load-\(index)"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    private static func spin(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        var sink = 0.0
        while Date() < end { sink += sin(sink + 1) }
        if sink.isNaN { print(sink) }
    }
}
#endif
