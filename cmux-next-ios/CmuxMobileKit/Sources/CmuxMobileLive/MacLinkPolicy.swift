import struct CmuxMobileModel.MacDevice
import Foundation

/// Which of the account's Macs the phone keeps a link to, at once: one link
/// per Mac, each with its own `LinkController` (dial, retry, TURN path,
/// heartbeat). Pure: the coordinator feeds it what is on screen and when
/// each Mac was last used, and runs the result (PROTOCOL.md "One link per
/// Mac").
///
/// - The focused Mac (the one the person chose, or the first online one) is
///   always targeted, offline included: its link says why it is not live.
/// - Another Mac is targeted only while it is wanted: something on screen
///   shows its data (the Workspaces list, the Feed, one of its workspaces),
///   or it was shown less than `idleAfter` ago. A Mac nothing asked for is
///   never dialed (lazy), and one left alone is closed (idle).
/// - A targeted Mac that presence calls offline is not dialed (its
///   `LinkMachine` waits in `macOffline`, or probes a live link: a signaling
///   reset says "offline" for a moment while the link is fine).
/// - A Mac whose pairing code the phone holds (`pinned`) is targeted next
///   after the focused one, so the code reaches it whatever else is shown.
/// - At most `maxLinks` Macs: the focused one, the pinned one, then online
///   Macs on screen, then online Macs by most recent use, then offline ones.
public struct MacLinkPolicy: Equatable, Sendable {
    /// The most Macs targeted at once.
    public var maxLinks: Int
    /// How long a Mac no longer on screen keeps its link.
    public var idleAfter: Duration

    public init(maxLinks: Int = 4, idleAfter: Duration = .seconds(300)) {
        self.maxLinks = max(1, maxLinks)
        self.idleAfter = idleAfter
    }

    public struct Decision: Equatable, Sendable {
        /// The Macs to target, focused first.
        public var linked: [String]
        /// When the next targeted Mac goes idle (nil: none will on its own).
        public var nextExpiry: ContinuousClock.Instant?
    }

    /// - Parameters:
    ///   - macs: the Macs this phone may dial, in list order.
    ///   - focused: the focused Mac (nil: none).
    ///   - showing: the Macs whose data is on screen now.
    ///   - lastShown: when each Mac was last on screen.
    ///   - pinned: the Mac a held pairing code names (nil: none).
    public func decide(macs: [MacDevice], focused: String?, showing: Set<String>,
                       lastShown: [String: ContinuousClock.Instant], now: ContinuousClock.Instant,
                       pinned: String? = nil) -> Decision {
        var linked: [String] = []
        if let focused, macs.contains(where: { $0.id == focused }) { linked.append(focused) }
        if let pinned, pinned != focused, linked.count < maxLinks, macs.contains(where: { $0.id == pinned }) {
            linked.append(pinned)
        }
        let others = macs.filter { $0.id != focused && $0.id != pinned }
        // Recent: no longer on screen, used within `idleAfter` (latest first).
        let recent = others
            .filter { !showing.contains($0.id) }
            .compactMap { mac -> (mac: MacDevice, at: ContinuousClock.Instant)? in
                guard let at = lastShown[mac.id], now - at < idleAfter else { return nil }
                return (mac, at)
            }
            .sorted { $0.at > $1.at }
        let shown = others.filter { showing.contains($0.id) }
        let wanted = shown.filter(\.isOnline) + recent.map(\.mac).filter(\.isOnline)
            + shown.filter { !$0.isOnline } + recent.map(\.mac).filter { !$0.isOnline }
        for mac in wanted where linked.count < maxLinks { linked.append(mac.id) }
        let expiries = recent.filter { linked.contains($0.mac.id) }.map { $0.at + idleAfter }
        return Decision(linked: linked, nextExpiry: expiries.min())
    }
}
