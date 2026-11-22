import Testing
@testable import CmuxNextTerminalGeometry

/// The rendered grid of a daemon-backed surface must equal the PTY's grid
/// whenever the stream is quiet, whatever the PTY owner did with the view's
/// reports. A visible mismatch is what makes zsh's PROMPT_SP mark `%` stay
/// on screen after Ctrl-C: zsh pads `%` to $COLUMNS, and a narrower mirror
/// wraps it onto its own line.
struct TerminalGridPolicyTests {
    static let replay = TerminalGridSize(columns: 80, rows: 24)
    static let view = TerminalGridSize(columns: 100, rows: 30)
    static let phone = TerminalGridSize(columns: 200, rows: 60)

    /// Minimal model of the daemon side of one terminal: the PTY size, who
    /// holds geometry, and `resized` announcements queued in stream order.
    struct FakePTYOwner {
        var pty: TerminalGridSize
        /// True while this view holds canonical geometry. A report from a
        /// view without it is passive: stored, not applied.
        var viewIsAuthority = true
        var lastViewReport: TerminalGridSize?
        var inFlight: [TerminalGridSize] = []
        var announcements: [TerminalGridSize] = []

        init(pty: TerminalGridSize) {
            self.pty = pty
            announcements = [pty]
        }

        mutating func receive(_ report: TerminalGridSize) { inFlight.append(report) }

        /// Applies the oldest report in flight.
        mutating func applyNext() {
            guard !inFlight.isEmpty else { return }
            let report = inFlight.removeFirst()
            lastViewReport = report
            guard viewIsAuthority else { return }
            resizePTY(to: report)
        }

        /// Another client (the phone) claims geometry at `size`.
        mutating func displace(to size: TerminalGridSize) {
            viewIsAuthority = false
            resizePTY(to: size)
        }

        /// The other client left; geometry returns to the view's last report.
        mutating func restore() {
            viewIsAuthority = true
            if let lastViewReport { resizePTY(to: lastViewReport) }
        }

        private mutating func resizePTY(to size: TerminalGridSize) {
            guard size != pty else { return }
            pty = size
            announcements.append(size)
        }
    }

    /// Delivers queued announcements to the policy in order.
    private func deliver(_ owner: inout FakePTYOwner, to policy: inout TerminalGridPolicy) {
        for grid in owner.announcements { policy.announce(grid) }
        owner.announcements.removeAll()
    }

    /// Runs everything in flight until the stream is quiet.
    private func settle(_ owner: inout FakePTYOwner, _ policy: inout TerminalGridPolicy) {
        deliver(&owner, to: &policy)
        while !owner.inFlight.isEmpty {
            owner.applyNext()
            deliver(&owner, to: &policy)
        }
    }

    @Test func ownerRendersThePTYGridWhileAnotherClientHoldsGeometry() {
        var owner = FakePTYOwner(pty: Self.replay)
        var policy = TerminalGridPolicy(ownsGeometry: true)
        if let report = policy.viewSized(Self.view, force: true) { owner.receive(report) }
        settle(&owner, &policy)
        #expect(policy.rendered == owner.pty)

        owner.displace(to: Self.phone)
        settle(&owner, &policy)
        #expect(policy.rendered == Self.phone)

        // The Mac pane resizes while the phone holds geometry: the report is
        // passive, the PTY stays at the phone's size.
        let narrower = TerminalGridSize(columns: 46, rows: 51)
        if let report = policy.viewSized(narrower) { owner.receive(report) }
        settle(&owner, &policy)
        #expect(owner.pty == Self.phone)
        #expect(policy.rendered == owner.pty)

        owner.restore()
        settle(&owner, &policy)
        #expect(owner.pty == narrower)
        #expect(policy.rendered == owner.pty)
    }

    @Test func ownerRendersThePTYGridAfterRandomResizes() {
        var rng = SplitMix64(seed: 0x5eed)
        for _ in 0..<200 {
            var owner = FakePTYOwner(pty: Self.replay)
            var policy = TerminalGridPolicy(ownsGeometry: true)
            if let report = policy.viewSized(Self.view, force: true) { owner.receive(report) }
            for _ in 0..<40 {
                switch rng.next() % 6 {
                case 0, 1, 2:
                    let grid = TerminalGridSize(columns: 20 + Int(rng.next() % 8), rows: 10 + Int(rng.next() % 4))
                    if let report = policy.viewSized(grid) { owner.receive(report) }
                case 3:
                    owner.applyNext()
                case 4:
                    deliver(&owner, to: &policy)
                default:
                    if owner.viewIsAuthority {
                        owner.displace(to: TerminalGridSize(columns: 30 + Int(rng.next() % 5), rows: 12))
                    } else {
                        owner.restore()
                    }
                }
                // Between deliveries the mirror shows the last grid the
                // stream announced.
                if owner.announcements.isEmpty { #expect(policy.rendered == owner.pty) }
            }
            settle(&owner, &policy)
            #expect(policy.rendered == owner.pty)
        }
    }

    @Test func followerAlwaysRendersTheAnnouncedGrid() {
        var policy = TerminalGridPolicy(ownsGeometry: false)
        #expect(policy.viewSized(Self.view, force: true) == nil)
        policy.announce(Self.replay)
        #expect(policy.rendered == Self.replay)
        #expect(policy.viewSized(Self.phone) == nil)
        #expect(policy.rendered == Self.replay)
    }

    @Test func eachDistinctViewGridIsReportedOnce() {
        var policy = TerminalGridPolicy(ownsGeometry: true)
        #expect(policy.viewSized(Self.view) == Self.view)
        #expect(policy.viewSized(Self.view) == nil)
        #expect(policy.viewSized(Self.phone) == Self.phone)
        #expect(policy.viewSized(Self.phone, force: true) == Self.phone)
    }
}

/// Deterministic generator so the random sequence is reproducible.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
