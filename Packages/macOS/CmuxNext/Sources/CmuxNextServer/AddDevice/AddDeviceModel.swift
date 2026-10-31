public import Foundation
public import Observation

/// The Add Device card's state (plans/cmux-next/add-device-DESIGN.md 2.3): which of the three ways
/// shows, the network's computers that are not added yet, and the platform of a new device. The
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
    /// The "Any machine: one line" way's state; nil while Labs `labs.machineJoin` is off.
    public private(set) var joinLine: MachineJoinLineModel?

    @ObservationIgnored private let services: AddDeviceServices
    /// The person picked a way: a late listing never moves them.
    @ObservationIgnored private var chosenByHand = false
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

    /// The card opens: back to the network way, and the network's computers read again.
    /// `way` opens on a way (the `machine.add` and `server.addServer` aliases, a CLI argument).
    public func begin(way: AddDeviceWay? = nil) async {
        generation += 1
        let mine = generation
        joinLine?.close()
        joinLine = services.machineJoin().map { MachineJoinLineModel(service: $0, clock: joinClock, sleep: joinSleep) }
        self.way = way.flatMap { ways.contains($0) ? $0 : nil } ?? .network
        chosenByHand = self.way == way
        copied = false
        candidates = .loading
        let listing = await services.list()
        guard mine == generation else { return }
        candidates = listing.map(Candidates.loaded) ?? .unavailable
        if !chosenByHand, available.isEmpty { self.way = .newDevice }
    }

    /// The ways the card offers: the three, plus "Any machine: one line" with Labs `labs.machineJoin` on.
    public var ways: [AddDeviceWay] {
        AddDeviceWay.allCases.filter { $0 != .joinLine || joinLine != nil }
    }

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
        guard ways.contains(way) else { return }
        chosenByHand = true
        copied = false
        self.way = way
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
        case .showMachines:
            services.showMachines()
            closeCard()
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
        switch joinLine?.phase {
        case .showing: [AddDeviceButton(action: .cancel, key: .escape), AddDeviceButton(action: .copyJoinLine, key: .return)]
        case .joined: [AddDeviceButton(action: .showMachines, key: nil), AddDeviceButton(action: .done, key: .return)]
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
