public import Foundation
public import Observation

/// The opt-in Cloud Tunnel's one state machine: Settings, `cmux cloud tunnel on|off|status` and
/// MCP all go through it.
///
/// Off by default, and while off it never touches SystemExtensions or NetworkExtension. A
/// turn-on (``enable()``, ``request(on:)``) requests the extension's activation (macOS asks the
/// user once), enrolls the `browser` peer, saves the VPN configuration and starts it. A launch
/// with the setting on (``restore(enabled:)``) starts the configuration a previous turn-on saved
/// and submits no activation request, so a launch never asks.
///
/// One transition runs at a time. A newer one supersedes it: a turn-off while macOS waits for
/// the person's approval ends that wait at once, and a superseded turn-on never installs or
/// starts anything after its next step. A turn-on while one is under way or up does nothing.
///
/// ```swift
/// let tunnel = CloudTunnelController(
///     availability: .available(extensionIdentifier: "com.cmuxterm.app.tunnel"),
///     activator: LiveSystemExtensionActivator(),
///     manager: LiveTunnelManager(),
///     enroller: enroller
/// )
/// let status = await tunnel.request(on: true)
/// ```
@MainActor
@Observable
public final class CloudTunnelController {
    /// Whether this build can run the tunnel.
    public enum Availability: Sendable, Equatable {
        /// The app bundles the extension and is signed to install it.
        case available(extensionIdentifier: String)
        /// It cannot; the text says why (shown as the status reason).
        case unavailable(String)
    }

    /// The tunnel's status, updated as it changes.
    public private(set) var status: CloudTunnelStatus = .off

    private var availability: Availability
    /// The launch probe of the bundle, until its answer is applied.
    @ObservationIgnored private var probing: Task<Availability, Never>?
    @ObservationIgnored private let activator: any SystemExtensionActivating
    @ObservationIgnored private let manager: any TunnelManaging
    @ObservationIgnored private let enroller: any CloudTunnelEnrolling
    @ObservationIgnored private var following: Task<Void, Never>?
    /// The latest transition; a newer one cancels it and waits for it to end.
    @ObservationIgnored private var transition: Task<Void, Never>?
    /// Which way the latest transition goes (`nil` before the first).
    @ObservationIgnored private var target: Bool?
    /// Bumped by every transition; a step of an older one does nothing.
    @ObservationIgnored private var generation = 0
    /// Whether the user wants the tunnel up; a disconnect then is a failure, not "off".
    @ObservationIgnored private var wantsUp = false
    /// Set once the started configuration reported progress, so the initial `disconnected` a
    /// fresh start reports is not taken for a failure.
    @ObservationIgnored private var started = false
    @ObservationIgnored private var stateWatch: Task<Void, Never>?
    @ObservationIgnored private var waiters: [Waiter] = []

    /// A ``request(on:)`` waiting for the status its transition settles in.
    private struct Waiter {
        let generation: Int
        let on: Bool
        let continuation: CheckedContinuation<CloudTunnelStatus, Never>
    }

    /// - Parameters:
    ///   - availability: Whether the bundle carries a usable extension.
    ///   - activator: Submits the activation request.
    ///   - manager: The saved VPN configuration.
    ///   - enroller: Enrolls the `browser` peer.
    public init(
        availability: Availability,
        activator: any SystemExtensionActivating,
        manager: any TunnelManaging,
        enroller: any CloudTunnelEnrolling
    ) {
        self.availability = availability
        self.activator = activator
        self.manager = manager
        self.enroller = enroller
        if case .unavailable(let reason) = availability { status = .unavailable(reason) }
    }

    /// The app's controller: its availability comes from `probe`, run off the main thread; every
    /// entry point waits for that answer first.
    /// - Parameters:
    ///   - probe: Decides whether this build bundles a usable extension.
    ///   - activator: Submits the activation request.
    ///   - manager: The saved VPN configuration.
    ///   - enroller: Enrolls the `browser` peer.
    public convenience init(
        probe: CloudTunnelBundleProbe,
        activator: any SystemExtensionActivating,
        manager: any TunnelManaging,
        enroller: any CloudTunnelEnrolling
    ) {
        self.init(availability: .unavailable(""), activator: activator, manager: manager, enroller: enroller)
        status = .off
        // task-owner: the controller; one probe, awaited by every entry point.
        probing = Task { await probe.availability() }
    }

    /// Follows the `cloud.tunnel.enabled` setting: its first value is the launch value
    /// (``restore(enabled:)``: off touches nothing, on never asks for approval); each later change
    /// starts a turn-on or turn-off without waiting for the one before, so a turn-off during
    /// approval takes effect at once. A second call replaces the first.
    /// - Parameter values: The setting's values, current one first.
    public func follow<Values: AsyncSequence & Sendable>(_ values: Values) where Values.Element == Bool {
        following?.cancel()
        // task-owner: the controller; ends with the sequence or the next follow.
        following = Task { [weak self] in
            var applied: Bool?
            do {
                for try await enabled in values where enabled != applied {
                    guard let self, !Task.isCancelled else { return }
                    if applied == nil {
                        await self.restore(enabled: enabled)
                    } else {
                        self.begin(on: enabled, reuseSaved: false)
                    }
                    applied = enabled
                }
            } catch {}
        }
    }

    /// Turns the tunnel on or off and returns the status that settles it: `connected`,
    /// `awaiting-approval` (macOS waits for the person) or `failed` for a turn-on, `off` or
    /// `failed` for a turn-off, `unavailable` for a build without the tunnel. A newer request
    /// ends the wait with the status at that moment.
    /// - Parameter on: `true` to turn the tunnel on.
    /// - Returns: The status the request settled in.
    public func request(on: Bool) async -> CloudTunnelStatus {
        begin(on: on, reuseSaved: false)
        if status.settles(turningOn: on) { return status }
        let generation = generation
        return await withCheckedContinuation { continuation in
            waiters.append(Waiter(generation: generation, on: on, continuation: continuation))
        }
    }

    /// Turns the tunnel on: activation (asking the user when needed), a fresh peer, start.
    /// Returns once the tunnel is starting, waiting for approval, or failed.
    public func enable() async {
        await begin(on: true, reuseSaved: false).value
    }

    /// Applies the saved setting at launch. Off: nothing at all. On: starts the configuration a
    /// previous turn-on saved, with no activation request; when there is none (the user quit
    /// before approving), it waits for an explicit turn-on instead of asking at launch.
    public func restore(enabled: Bool) async {
        await settleAvailability()
        guard enabled, case .available = availability else { return }
        let saved: Bool
        do {
            saved = try await manager.loadSaved()
        } catch {
            update(.failed(Self.message(error)))
            return
        }
        guard saved else {
            update(.failed(String(
                localized: "cloudTunnel.status.finishSetup",
                defaultValue: "Setup was not finished. Turn the Cloud Tunnel on again.",
                bundle: .module
            )))
            return
        }
        await begin(on: true, reuseSaved: true).value
    }

    /// Turns the tunnel off and removes its VPN configuration. The extension stays installed
    /// (removing it needs the user's password), idle.
    public func disable() async {
        await begin(on: false, reuseSaved: false).value
    }

    /// Starts a transition, or returns the running one when it already goes that way.
    @discardableResult
    private func begin(on: Bool, reuseSaved: Bool) -> Task<Void, Never> {
        if probing == nil, case .unavailable = availability { return Task {} }
        if target == on, let transition {
            // Already turning that way, and it has not failed: join it.
            switch status {
            case .connecting, .awaitingApproval, .connected:
                if on { return transition }
            case .disconnecting, .off:
                if !on { return transition }
            case .failed, .unavailable:
                break
            }
        }
        if !on, target == nil, status == .off { return Task {} }
        generation += 1
        let generation = generation
        target = on
        wantsUp = on
        let previous = transition
        previous?.cancel()
        update(on ? .connecting : .disconnecting)
        // task-owner: the controller; a newer transition cancels it and awaits its end.
        let task = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            if on {
                await self.runOn(generation, reuseSaved: reuseSaved)
            } else {
                await self.runOff(generation)
            }
            self.finished(generation)
        }
        transition = task
        return task
    }

    private func runOn(_ generation: Int, reuseSaved: Bool) async {
        await settleAvailability()
        guard isCurrent(generation) else { return }
        guard case .available(let identifier) = availability else {
            wantsUp = false
            return
        }
        started = false
        if !reuseSaved {
            guard await activate(identifier, generation) else { return }
            guard isCurrent(generation) else { return }
            update(.connecting)
        }
        do {
            let saved = try await manager.loadSaved()
            guard isCurrent(generation) else { return }
            if !(reuseSaved && saved) {
                let wgQuick = try await enroller.enrollBrowserPeer()
                guard isCurrent(generation) else { return }
                let configuration = try CloudTunnelConfiguration(wgQuick: wgQuick)
                try await manager.install(configuration, providerBundleIdentifier: identifier)
                guard isCurrent(generation) else { return }
            }
            watchStates()
            try manager.start()
        } catch {
            guard isCurrent(generation) else { return }
            wantsUp = false
            update(.failed(Self.message(error)))
        }
    }

    private func runOff(_ generation: Int) async {
        await settleAvailability()
        guard isCurrent(generation), case .available = availability else { return }
        stateWatch?.cancel()
        stateWatch = nil
        manager.stop()
        do {
            try await manager.remove()
            if isCurrent(generation) { update(.off) }
        } catch {
            if isCurrent(generation) { update(.failed(Self.message(error))) }
        }
    }

    private func isCurrent(_ generation: Int) -> Bool {
        generation == self.generation && !Task.isCancelled
    }

    /// The transition `generation` ended: its waiters get the status it left, except a started
    /// tunnel's, which wait for the connection to settle (connected or failed).
    private func finished(_ generation: Int) {
        guard generation == self.generation else { return }
        if wantsUp, status == .connecting, stateWatch != nil { return }
        resumeWaiters(all: true)
    }

    /// Applies the launch probe's answer once.
    private func settleAvailability() async {
        guard let probing else { return }
        let answer = await probing.value
        guard self.probing != nil else { return }
        self.probing = nil
        availability = answer
        if case .unavailable(let reason) = answer {
            wantsUp = false
            update(.unavailable(reason))
        }
    }

    /// Runs the activation request; `false` when it did not end activated (status says why) or a
    /// newer transition ended the wait.
    private func activate(_ identifier: String, _ generation: Int) async -> Bool {
        for await event in activator.activate(identifier: identifier) {
            guard isCurrent(generation) else { return false }
            switch event {
            case .needsApproval:
                update(.awaitingApproval)
            case .activated:
                return true
            case .willCompleteAfterReboot:
                wantsUp = false
                update(.failed(String(
                    localized: "cloudTunnel.status.reboot",
                    defaultValue: "Restart your Mac to finish installing the cmux Cloud Tunnel.",
                    bundle: .module
                )))
                return false
            case .failed(let reason):
                wantsUp = false
                update(.failed(reason))
                return false
            }
        }
        guard isCurrent(generation) else { return false }
        wantsUp = false
        update(.failed(String(
            localized: "cloudTunnel.status.activationEnded",
            defaultValue: "macOS did not finish installing the cmux Cloud Tunnel.",
            bundle: .module
        )))
        return false
    }

    private func watchStates() {
        stateWatch?.cancel()
        let states = manager.states()
        // task-owner: the controller; cancelled by a turn-off or the next start.
        stateWatch = Task { [weak self] in
            for await state in states {
                guard !Task.isCancelled, let self else { return }
                self.apply(state)
            }
        }
    }

    private func apply(_ state: CloudTunnelConnectionState) {
        switch state {
        case .connecting, .reasserting:
            started = true
            update(.connecting)
        case .connected(let since):
            started = true
            update(.connected(since: since))
        case .disconnecting:
            update(.disconnecting)
        case .disconnected, .invalid:
            guard started else { return }
            update(wantsUp
                ? .failed(String(
                    localized: "cloudTunnel.status.stopped",
                    defaultValue: "The Cloud Tunnel stopped. Turn it off and on to retry.",
                    bundle: .module
                ))
                : .off)
        }
    }

    private func update(_ new: CloudTunnelStatus) {
        status = new
        resumeWaiters(all: false)
    }

    /// Resumes each waiter whose status settled, whose transition was superseded, or (`all`) every one.
    private func resumeWaiters(all: Bool) {
        guard !waiters.isEmpty else { return }
        var waiting: [Waiter] = []
        for waiter in waiters {
            if all || waiter.generation != generation || status.settles(turningOn: waiter.on) {
                waiter.continuation.resume(returning: status)
            } else {
                waiting.append(waiter)
            }
        }
        waiters = waiting
    }

    private static func message(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
