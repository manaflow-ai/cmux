public import CmuxNextCompat
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
public nonisolated enum ShareHostDevice {
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
    @MainActor static func daemonHub(_ devices: CmuxRemoteDevices, socketPath path: String,
                                     make: (DeviceIdentity) -> DeviceHub) async throws -> DeviceHub? {
        guard let found = await identity(devices, socketPath: path) else { return nil }
        guard let daemonUser = found.userID else {
            shareHostLogger.info("device hub: the acpmux daemon's device is not signed in; using the app's")
            return nil
        }
        let hub = make(found.identity)
        guard try await hub.client.accountSession().userId == daemonUser else {
            shareHostLogger.info("device hub: the acpmux daemon's device is another account's; using the app's")
            return nil
        }
        hub.ownsDevice = false
        return hub
    }

    /// From now on `deviceHub` makes its hub with the daemon's device whenever ``daemonHub(_:socketPath:make:)`` gives one (its channel
    /// answers for the app's account), checked at each hub start (sign-in, another account or address, each retry), never
    /// polled. Else it uses what it used before: the cmux Remote worker's device when this build runs
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
        let devices = channel(socketPath: path)
        let link = Link()
        let worker = deviceHub.makeRemoteHub, workerChanged = deviceHub.hubChanged
        deviceHub.makeRemoteHub = { url, user in
            link.made = nil
            if let hub = try await ShareHostDevice.daemonHub(devices, socketPath: path, make: { identity in
                devices.makeHub(url: url, identity: identity, bundleID: bundleID, loginKeychain: loginKeychain, tokens: tokens)
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

    /// The hub made with the daemon's device, and the one running now.
    @MainActor private final class Link {
        weak var made: DeviceHub?
        weak var running: DeviceHub?
    }
}
