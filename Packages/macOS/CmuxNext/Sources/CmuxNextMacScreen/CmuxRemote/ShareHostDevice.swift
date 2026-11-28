public import CmuxNextCompat
import CCmuxDaemonConnFFI
import CmuxNextDevices
import Darwin
public import Foundation
import os

private let shareHostLogger = Logger(subsystem: "com.cmuxterm.app.next", category: "share-host-device")

/// This Mac's device hub identity when the acpmux daemon's share host owns it (the Mac is one
/// device: hq docs/design/remote-screen-share-zero-touch.md, Z5). The daemon keeps the device key
/// and the one User DO socket; its channel `<acpmux home>/share-host/device.sock` speaks the cmux
/// Remote Screen Sharing worker's JSON lines, so ``CmuxRemoteDevices`` is its client unchanged. The
/// daemon decides who serves each host ticket and says so in the relayed push (`servedBy`); the app
/// only follows it (``MacScreenHubHost``).
public nonisolated struct ShareHostDevice {
    public nonisolated init() {}
    /// `<acpmux home>/share-host/device.sock`.
    public static func socketPath(acpmuxHome: URL) -> String {
        acpmuxHome.appending(path: "share-host/device.sock", directoryHint: .notDirectory).path
    }

    /// `<acpmux home>/share-host/device.sock` for `build` (`~/.acpmux` for NIGHTLY, the join's
    /// daemon; `~/.acpmux/builds/<key>` for others), the home found from the user's password entry
    /// (`getpwuid`), never `HOME` or `ACPMUX_HOME`, as JoinConsent+App.swift finds acpmux's consent
    /// folder; nil without one.
    static func socketPath(build: BuildIdentity) -> String? {
        guard let home = getpwuid(geteuid())?.pointee.pw_dir else { return nil }
        return socketPath(acpmuxHome: build.acpmuxHome(userHome: URL(fileURLWithPath: String(cString: home), isDirectory: true)))
    }

    /// The daemon's channel at `path`: a Unix socket whose peer runs as this user. The connect runs
    /// on a detached task (a channel may open from a main-actor caller).
    static func channel(socketPath path: String) -> CmuxRemoteDevices {
        CmuxRemoteDevices(open: {
            // task-owner: one connect off the caller's actor; the channel's opener awaits it.
            try await Task.detached(priority: .userInitiated) { try ShareHostDevice.connect(path) }.value
        })
    }

    private static func connect(_ path: String) throws -> Int32 {
        let descriptor = try RemoteSocket.connect(path)
        guard RemoteSocket.peerUID(descriptor) == geteuid() else {
            Darwin.close(descriptor)
            throw CmuxRemoteError.refused("the share host's socket is not this user's")
        }
        return descriptor
    }

    /// The daemon's device identity when its channel exists and answers `device.identity`, else nil.
    /// Bounded by the channel's timeout, so a daemon that accepts and never answers falls through.
    /// With it, the hub user the daemon signed in as (`user_id`), nil while it is not signed in.
    static func identity(_ devices: CmuxRemoteDevices, socketPath path: String) async -> (identity: DeviceIdentity, userID: String?)? {
        // task-owner: one bounded identity read off the main actor; the caller awaits it.
        // No daemon: the connect fails at once (no socket at `path`), and so does the read.
        await Task.detached(priority: .userInitiated) { () -> (identity: DeviceIdentity, userID: String?)? in
            try? devices.blockingIdentityAndUser()
        }.value
    }

    /// The hub `make` builds with the daemon's device, when its channel answers and the daemon is
    /// signed in as the app's own hub user; else nil (no daemon, no `user_id`, another account), and
    /// the app keeps the worker's or its own identity. The app's user comes from the account
    /// exchange (`/v1/auth/stack`, not device-signed), which the hub then keeps; when it fails this
    /// throws, so the hub start retries instead of switching devices. The daemon registers the
    /// device and holds its sign-in: the hub is made with ``DeviceHub/ownsDevice`` false.
    /// `declined` hears the daemon's user when it is another account's.
    @MainActor static func daemonHub(_ devices: CmuxRemoteDevices, socketPath path: String, declined: (String) -> Void = { _ in },
                                     make: (DeviceIdentity) -> DeviceHub) async throws -> DeviceHub? {
        guard let found = await identity(devices, socketPath: path) else { return nil }
        guard let daemonUser = found.userID else {
            shareHostLogger.info("device hub: the acpmux daemon's device is not signed in; using the app's")
            return nil
        }
        let hub = make(found.identity)
        guard try await hub.client.accountSession().userId == daemonUser else {
            shareHostLogger.info("device hub: the acpmux daemon's device is another account's; using the app's")
            declined(daemonUser)
            return nil
        }
        hub.ownsDevice = false
        return hub
    }

    /// From now on `deviceHub` makes its hub with the daemon's device whenever ``daemonHub(_:socketPath:declined:make:)`` gives one (its
    /// channel answers for the app's account), checked at each hub start (sign-in, another account or address, each retry) and
    /// again each time the daemon says it came online as a device the running hub is not (``follow(_:in:devices:link:)``). Else it uses what it used before: the cmux Remote worker's device when this build runs
    /// it (the `makeRemoteHub` already set), else the app's own Secure Enclave identity. Call after
    /// cmux Remote set its hooks and before ``DeviceHubService/start(settings:)``.
    @MainActor public static func prefer(in deviceHub: DeviceHubService, build: BuildIdentity, bundleID: String?, loginKeychain: LoginKeychain,
                                         tokens: @escaping @Sendable () async throws -> String) {
        guard let path = socketPath(build: build) else { return }
        prefer(in: deviceHub, socketPath: path, bundleID: bundleID ?? "com.cmuxterm.app.next", loginKeychain: loginKeychain, tokens: tokens)
    }

    /// ``prefer(in:build:bundleID:loginKeychain:tokens:)`` with the daemon's channel at `path`.
    @MainActor static func prefer(in deviceHub: DeviceHubService, socketPath path: String, bundleID: String, loginKeychain: LoginKeychain,
                                  tokens: @escaping @Sendable () async throws -> String) {
        // The daemon's device signs in with its machine credential, which names no build: it is a device of the hub's
        // default space. A tagged dev build's hub is its own space's (``DeviceHubService/buildSpace``), so it keeps the
        // worker's or its own identity there instead of adopting a device whose socket lives in another space.
        guard deviceHub.buildSpace == .nightly else {
            shareHostLogger.info("device hub: a dev build space; the acpmux daemon's device is not used")
            return
        }
        let devices = channel(socketPath: path)
        let link = Link()
        let worker = deviceHub.makeRemoteHub, workerChanged = deviceHub.hubChanged
        deviceHub.makeRemoteHub = { url, user in
            link.made = nil
            link.declined = nil
            if let hub = try await ShareHostDevice.daemonHub(devices, socketPath: path, declined: { link.declined = $0 }, make: { identity in
                devices.makeHub(url: url, identity: identity, bundleID: bundleID, loginKeychain: loginKeychain, buildSpace: .nightly, tokens: tokens)
            }) {
                link.made = hub
                shareHostLogger.info("device hub: this Mac's device is the acpmux daemon's")
                return hub
            }
            return try await worker?(url, user)
        }
        deviceHub.hubChanged = { hub, user, url in
            workerChanged?(hub, user, url)
            let wasDaemons = link.running != nil
            link.running = hub.flatMap { $0 === link.made ? $0 : nil }
            link.watch?.cancel()
            link.watch = hub.map { follow($0, in: deviceHub, devices: devices, link: link) }
            // Recorded by the daemon for `acpmux share-host status` (which account and hub the app runs).
            if link.running != nil, let user, let url {
                // task-owner: one status line to the daemon; nothing waits on it.
                Task.detached(priority: .utility) { await devices.anchored(userID: user, hubURL: url) }
            } else if wasDaemons {
                // task-owner: one status line to the daemon; nothing waits on it.
                Task.detached(priority: .utility) { await devices.signedOut() }
            }
        }
    }

    /// While `hub` runs: each time the daemon comes online (`device.watch`) as a device `hub` is not, for an account the
    /// last pick did not decline, `deviceHub` starts its hub again and picks the daemon's. That is the app that asked before
    /// the daemon was up or signed in (it took the worker's or its own identity, which the hub then shows offline beside
    /// the daemon's online one), or that holds a device the daemon replaced. A channel that ends (no daemon yet, one
    /// restarting) opens again after a Rust-paced backoff, capped at 30 s.
    @MainActor private static func follow(_ hub: DeviceHub, in deviceHub: DeviceHubService, devices: CmuxRemoteDevices,
                                          link: Link) -> Task<Void, Never> {
        // task-owner: Link.watch: lives with the running hub; the next hubChanged cancels it.
        Task.detached(priority: .utility) { [weak deviceHub, weak hub, weak link] in
            var retry = cmux_retry_pacer_new(cmux_retry_policy_new(1_000_000_000, 30_000_000_000, 10, 0, true))
            // wakeup-allow: a watch channel that ends or cannot open suspends for Rust backoff (capped at 30s); the daemon's
            // events wake it otherwise, and cancellation (another hub) ends it.
            while !Task.isCancelled {
                for await online in devices.onlineEvents() {
                    guard let deviceHub, let hub, let link else { return }
                    if await restart(deviceHub, replacing: hub, for: online, link: link) { return }
                }
                let delay = cmux_retry_pacer_failed(&retry, Double.random(in: 0..<1))
                guard delay >= 0 else { return }
                // wakeup-allow: cancellable backoff before the watch channel opens again, paced by Rust and capped at 30s.
                do { try await ContinuousClock().sleep(for: .nanoseconds(delay)) } catch { return }
            }
        }
    }

    /// Starts `deviceHub`'s hub again when the daemon came online as `online` and ``shouldFollow(_:running:declined:)``
    /// says `hub` should give way to it; whether it did.
    @MainActor private static func restart(_ deviceHub: DeviceHubService, replacing hub: DeviceHub, for online: ShareHostOnline,
                                           link: Link) -> Bool {
        guard shouldFollow(online, running: hub.identity.id, declined: link.declined) else { return false }
        shareHostLogger.info("device hub: the acpmux daemon is online as another device; following it")
        deviceHub.restartHub(replacing: hub)
        return true
    }

    /// Whether the daemon online as `online` should replace the running hub's device `running`: another device, of an
    /// account the last pick did not find to be another one's.
    nonisolated static func shouldFollow(_ online: ShareHostOnline, running: String, declined: String?) -> Bool {
        online.id != running.lowercased() && online.userID != declined
    }

    /// The hub made with the daemon's device, the one running now, the daemon's user the last pick found to be another
    /// account's, and the watch that follows the daemon while a hub runs.
    @MainActor private final class Link {
        weak var made: DeviceHub?
        weak var running: DeviceHub?
        var declined: String?
        var watch: Task<Void, Never>?
    }
}
