public import Foundation
public import Observation

/// The Add Device card's state (plans/cmux-next/add-device-DESIGN.md 2.3): which way shows (the
/// pair code first, ssh behind Advanced), the network's computers that are not added yet, and the
/// platform of a new device. The
/// card hands off to the Add Machine and Add Server cards, so there is still one enroll and one
/// approval; this model only decides which one and with what. The click and the key run
/// ``perform(_:)``.
@MainActor @Observable
public final class AddDeviceModel {
    /// The network's computers that are not added yet.
    public nonisolated enum Candidates: Equatable, Sendable {
        case loading
        case loaded(DeviceListing)
        /// The CLI is missing or failed: the network way says so and offers a name instead.
        case unavailable
    }

    public private(set) var way: AddDeviceWay = .network
    public private(set) var candidates: Candidates = .loading
    public var platform: AddDevicePlatform = .macOrLinux
    /// The line was copied (the button says so until the platform or way changes).
    public private(set) var copied = false
    /// The "Any machine" way's state; nil when the app offers no join (tests, a cmux without the CLI
    /// seam), and then the card keeps its three ssh-first ways.
    public private(set) var joinLine: MachineJoinLineModel?
    /// Signed in, the "Any machine" way offers Pair Another Machine (a code the new machine types,
    /// no ssh) in place of the ticket line; signed out, the ticket line shows as before.
    public private(set) var offersInvite = false
    @ObservationIgnored private var openInvite: (() -> Void)?

    @ObservationIgnored private let services: AddDeviceServices
    /// The person picked a way: a late listing never moves them.
    @ObservationIgnored private var chosenByHand = false
    /// The way the card was on before Advanced opened: closing Advanced goes back to it.
    @ObservationIgnored private var beforeAdvanced: AddDeviceWay?
    @ObservationIgnored private var generation = 0

    @ObservationIgnored private let joinClock: @Sendable () -> Date
    @ObservationIgnored private let joinSleep: @Sendable (Duration) async throws -> Void

    /// `joinClock` and `joinSleep` drive the join line's countdown (tests move time by hand).
    public init(services: AddDeviceServices, joinClock: @escaping @Sendable () -> Date = { Date() },
                joinSleep: @escaping @Sendable (Duration) async throws -> Void = MachineJoinLineModel.taskSleep) {
        self.services = services
        self.joinClock = joinClock
        self.joinSleep = joinSleep
    }

    /// The card opens: back to the default way (``defaultWay``), and the network's computers read
    /// again. `way` opens on a way (the `machine.add` and `server.addServer` aliases, a CLI argument).
    public func begin(way: AddDeviceWay? = nil) async {
        generation += 1
        let mine = generation
        joinLine?.close()
        joinLine = services.machineJoin().map { MachineJoinLineModel(service: $0, clock: joinClock, sleep: joinSleep) }
        openInvite = joinLine == nil ? nil : services.pairAnotherMachine()
        offersInvite = openInvite != nil
        self.way = way.flatMap { allWays.contains($0) ? $0 : nil } ?? defaultWay
        chosenByHand = self.way == way
        beforeAdvanced = nil
        copied = false
        candidates = .loading
        let listing = await services.list()
        guard mine == generation else { return }
        candidates = listing.map(Candidates.loaded) ?? .unavailable
        // Only the ssh-first card moves to setup when the network has nothing to add; the pair code
        // works whatever the network lists.
        if !chosenByHand, self.way == .network, available.isEmpty { self.way = .newDevice }
    }

    /// The way the card opens on: the pair code (no ssh) when the app offers it, else the network.
    public var defaultWay: AddDeviceWay { joinLine == nil ? .network : .joinLine }

    /// The ways the card's switch shows. With the join offered: "Any machine" (the pair code) first,
    /// then "It shows a code" and "Set up a new device"; ssh moves behind Advanced
    /// (``advancedWays``). Without it, the three ssh-first ways as before.
    public var ways: [AddDeviceWay] {
        joinLine == nil ? [.network, .code, .newDevice] : [.joinLine, .code, .newDevice]
    }

    /// The ways behind the Advanced disclosure: ssh (``AddDeviceWay/network``, Add Machine's enroll),
    /// which still works as before. Empty when the switch already shows it.
    public var advancedWays: [AddDeviceWay] { joinLine == nil ? [] : [.network] }

    /// Every way the card can show, in the switch or behind Advanced.
    public var allWays: [AddDeviceWay] { ways + advancedWays }

    /// Advanced is open: the card shows one of ``advancedWays`` (the switch then has no selection).
    public var showsAdvanced: Bool { advancedWays.contains(way) }

    /// The computers the network way lists, the person's own first.
    public var available: [DeviceListing.Available] {
        guard case let .loaded(listing) = candidates else { return [] }
        return listing.available
    }

    /// The network's state when it is not up (no Tailscale, signed out), for the network way. The
    /// computers of the person's ~/.ssh/config still list under it.
    public var networkProblem: String? {
        guard case let .loaded(listing) = candidates, !listing.network.up else { return nil }
        return listing.network.detail
    }

    public var canInstallTailscale: Bool {
        guard case let .loaded(listing) = candidates else { return false }
        return listing.network.kind == "none" && !listing.network.up
    }

    public func choose(_ way: AddDeviceWay) {
        guard allWays.contains(way) else { return }
        chosenByHand = true
        copied = false
        if advancedWays.contains(way), !showsAdvanced { beforeAdvanced = self.way }
        self.way = way
    }

    /// The Advanced disclosure: opening it shows ssh (``AddDeviceWay/network``); closing it goes back
    /// to the way the card was on.
    public func toggleAdvanced() {
        guard let advanced = advancedWays.first else { return }
        if showsAdvanced {
            choose(beforeAdvanced.flatMap { ways.contains($0) ? $0 : nil } ?? defaultWay)
        } else {
            choose(advanced)
        }
    }

    public func choose(_ platform: AddDevicePlatform) {
        copied = false
        self.platform = platform
    }

    /// The footer for the current way: an Escape button, and a Return button where one fits.
    public var buttons: [AddDeviceButton] {
        switch way {
        case .network:
            [AddDeviceButton(action: .cancel, key: .escape), AddDeviceButton(action: .newCloudMachine, key: nil),
             AddDeviceButton(action: .otherComputer, key: nil)]
        case .code:
            [AddDeviceButton(action: .cancel, key: .escape), AddDeviceButton(action: .enterCode, key: .return)]
        case .newDevice where platform == .phone:
            [AddDeviceButton(action: .done, key: .return)]
        case .joinLine:
            joinLineButtons
        case .newDevice:
            // A computer: New Cloud VM… stays at hand, as on the network way (the card opens here
            // when the network lists nothing to add).
            [AddDeviceButton(action: .cancel, key: .escape), AddDeviceButton(action: .newCloudMachine, key: nil),
             AddDeviceButton(action: .copyLine, key: .return)]
        }
    }

    /// "Set up a new device" for a computer also offers Other Computer… (add by host name): the card
    /// opens there when the network lists nothing, and a computer the person already reaches with
    /// ssh needs no setup line (HQ #4877 break 5).
    public var offersOtherComputer: Bool {
        way == .newDevice && platform.setupLine != nil
    }

    /// Runs a control (its click or its key). Returns true when the card should close.
    @discardableResult
    public func perform(_ action: AddDeviceAction) -> Bool {
        switch action {
        case let .pick(computer):
            services.addComputer(computer.address, computer.name)
            return true
        case .otherComputer:
            services.addByName()
            return true
        case .newCloudMachine:
            services.newCloudMachine()
            return true
        case .enterCode:
            services.enterCode()
            return true
        case .installTailscale:
            if canInstallTailscale { services.installTailscale() }
            return false
        case .copyLine:
            guard let line = platform.setupLine else { return false }
            services.copy(line)
            copied = true
            return false
        case .copyJoinLine:
            guard let line = joinLine?.line else { return false }
            services.copyConcealed(line.line)
            joinLine?.markCopied()
            return false
        case .makeJoinLine, .newJoinLine:
            mintJoinLine()
            return false
        case .signIn:
            services.signIn()
            closeCard()
            return true
        case .showMachines:
            services.showMachines()
            closeCard()
            return true
        case .toggleAdvanced:
            toggleAdvanced()
            return false
        case .pairAnotherMachine:
            guard let openInvite else { return false }
            closeCard()
            openInvite()
            return true
        case .done, .cancel:
            closeCard()
            return true
        }
    }

    /// The card closes: a late listing or mint is dropped, and the join line's countdown and mesh
    /// watch stop (``MachineJoinLineModel/close()``).
    public func closeCard() {
        generation += 1
        joinLine?.close()
    }

    private var joinLineButtons: [AddDeviceButton] {
        if offersInvite { return [AddDeviceButton(action: .cancel, key: .escape), AddDeviceButton(action: .pairAnotherMachine, key: .return)] }
        return switch joinLine?.phase {
        case .showing: [AddDeviceButton(action: .cancel, key: .escape), AddDeviceButton(action: .copyJoinLine, key: .return)]
        case .joined: [AddDeviceButton(action: .showMachines, key: nil), AddDeviceButton(action: .done, key: .return)]
        // Signed out, a new line would be refused again: Sign In instead (msg 3790).
        case .failed(.signedOut): [AddDeviceButton(action: .cancel, key: .escape), AddDeviceButton(action: .signIn, key: .return)]
        case .expired, .failed: [AddDeviceButton(action: .cancel, key: .escape), AddDeviceButton(action: .newJoinLine, key: .return)]
        case .idle: [AddDeviceButton(action: .cancel, key: .escape), AddDeviceButton(action: .makeJoinLine, key: .return)]
        case .minting, nil: [AddDeviceButton(action: .cancel, key: .escape)]
        }
    }

    private func mintJoinLine() {
        guard let joinLine else { return }
        // task-owner: one mint per click; a newer mint or close() supersedes it (its generation).
        Task { await joinLine.mint() }
    }
}
