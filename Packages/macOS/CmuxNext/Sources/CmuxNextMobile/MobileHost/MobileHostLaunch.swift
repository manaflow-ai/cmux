public import Foundation

/// How the app starts one `cmux-mobile-host` (cmux-next-ios/rust/README.md lists its
/// variables). Pure: ``environment`` is what the child gets, and nothing of
/// the app's own environment leaks into it beyond `HOME`, `PATH` and `TMPDIR`.
public struct MobileHostLaunch: Sendable, Equatable {
    /// The bundled `Contents/Resources/bin/cmux-mobile-host`.
    public var executable: URL
    /// The mobile service (`https://cmux-mobile-api-<env>.debussy.workers.dev`).
    public var baseURL: URL
    /// The Stack team, or `personal-<userId>` (PROTOCOL.md "Personal space").
    public var teamID: String
    /// The signed-in Stack user: only this user's phones are admitted.
    public var userID: String
    /// This Mac's persistent mobile device id (``MobileHostDeviceIdentity``).
    public var deviceID: String
    /// How phones list this Mac: the computer name.
    public var deviceName: String
    /// The app's own cmux-tui daemon socket.
    public var daemonSocket: String
    /// hostd's state directory (the app's, per bundle id).
    public var stateDirectory: URL
    /// Folders the phone's `file` service may read; empty denies every read.
    public var fileRoots: [String]
    /// Stack project and publishable key, for hostd's own token checks.
    public var stackProjectID: String
    /// The `agent_session.host` this app records on its own agent tabs (`install:<id>`):
    /// hostd sets it on an agent tab a phone creates, so the chat runs on this Mac's
    /// acpmux and shows here as this Mac's own. Nil: phones cannot create agent tabs.
    public var agentTabHost: String?
    /// The Chief's conversation owner session (`ChiefHome.session`), served
    /// to phones by hostd's scoped `chief` service. The app always sets it from
    /// its own Chief home (`IPhoneHostService.Dependencies.chief`): a DEV or
    /// tagged build's Chief lives at `~/.cmux/chief/<bundle id>`, not the
    /// `~/.cmux/chief/default` hostd derives when it is nil (only a hostd
    /// started by hand relies on that).
    public var chiefSession: String?
    /// The Chief owner's socket once the app is connected to it
    /// (`ChiefConversationOwner.socketPath()`): hostd dials it as is
    /// (`CMUX_MOBILE_CHIEF_SOCKET`), so a socket outside the app daemon's folder
    /// (cmux-tui's short-path fallback) is still found.
    public var chiefSocket: String?
    /// This build streams the phone's browser tabs (a bundled remote browser host):
    /// hostd serves `browser` and says `browser-stream-v1` (`CMUX_MOBILE_BROWSER_HOSTS=1`).
    /// Off, phones hide New Browser Tab for this Mac.
    public var browserHosts = false
    /// This build streams surfaces (the phone tabs' simulators when SimulatorKit loads, the owner's
    /// Cloud desktops): hostd serves `surface` and says `surface-stream-v1` and `cloud-desktop-v1`
    /// (`CMUX_MOBILE_SURFACE_HOSTS=1`).
    public var surfaceHosts = false
    /// The surface source streams phone tabs' simulators too; off (no SimulatorKit), hostd streams
    /// Cloud desktops only and says no `surface-stream-v1` (`CMUX_MOBILE_SURFACE_SIMULATORS=0`).
    public var simulatorSurfaces = true

    public init(executable: URL, baseURL: URL, teamID: String, userID: String, deviceID: String, deviceName: String,
                daemonSocket: String, stateDirectory: URL, fileRoots: [String], stackProjectID: String,
                agentTabHost: String? = nil) {
        self.executable = executable
        self.baseURL = baseURL
        self.teamID = teamID
        self.userID = userID
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.daemonSocket = daemonSocket
        self.stateDirectory = stateDirectory
        self.fileRoots = fileRoots
        self.stackProjectID = stackProjectID
        self.agentTabHost = agentTabHost
    }

    /// The team hostd joins: the selected Stack team, else the personal space.
    public static func teamID(selected: String?, userID: String) -> String {
        if let selected, !selected.isEmpty { return selected }
        return "personal-\(userID)"
    }

    /// A test rig's machine id for cmux-mobile-host, set at launch (`open
    /// --env`). The app strips every inherited `CMUX*` variable at launch but
    /// the `CMUX_NEXT_*` knobs (`LaunchIdentity.inheritedKeys`), so the rig's
    /// variable is a `CMUX_NEXT_` one, passed on as `CMUX_MOBILE_MACHINE_ID`.
    public static let rigMachineIDKey = "CMUX_NEXT_MOBILE_MACHINE_ID"

    /// The child's whole environment. `inherited` supplies only `HOME`, `PATH`
    /// and `TMPDIR`, and in a DEBUG (tagged dev) build ``rigMachineIDKey`` when
    /// set: a test rig's own machine id, so several hidden rig apps on one Mac
    /// are listed apart on the phone. cmux-mobile-host checks its form (32 hex
    /// digits) and otherwise uses this computer's id. Release builds never
    /// pass it, like the test pairing seed (SECURITY.md).
    public func environment(inherited: [String: String]) -> [String: String] {
        var environment: [String: String] = [:]
        for key in ["HOME", "PATH", "TMPDIR"] { environment[key] = inherited[key] }
        #if DEBUG
        if let machineID = inherited[Self.rigMachineIDKey], !machineID.isEmpty {
            environment["CMUX_MOBILE_MACHINE_ID"] = machineID
        }
        #endif
        let socket = URL(fileURLWithPath: daemonSocket)
        var session = socket.lastPathComponent
        if session.hasSuffix(".sock") { session.removeLast(5) }
        environment.merge([
            "CMUX_MOBILE_CONTROL": "stdio",
            "CMUX_MOBILE_BASE_URL": baseURL.absoluteString,
            "CMUX_MOBILE_TEAM_ID": teamID,
            "CMUX_MOBILE_OWNER_USER_ID": userID,
            "CMUX_MOBILE_DEVICE_ID": deviceID,
            "CMUX_MOBILE_DEVICE_NAME": deviceName,
            "CMUX_MOBILE_STATE_DIR": stateDirectory.path,
            "CMUX_MOBILE_TUI_SOCKET": daemonSocket,
            "CMUX_MOBILE_TUI_SOCKET_DIR": socket.deletingLastPathComponent().path,
            "CMUX_MOBILE_TUI_SESSION": session,
            "CMUX_MOBILE_FILE_ROOTS": fileRoots.joined(separator: ":"),
            "CMUX_MOBILE_STACK_PROJECT_ID": stackProjectID,
            // Tailscale addresses are the user's own overlay, not a path a phone
            // outside it can use; run-host.sh excludes them the same way.
            "CMUX_MOBILE_EXCLUDE_CGNAT": "1",
            "NO_COLOR": "1",
        ]) { $1 }
        if let agentTabHost, !agentTabHost.isEmpty { environment["CMUX_MOBILE_AGENT_TAB_HOST"] = agentTabHost }
        if let chiefSession, !chiefSession.isEmpty { environment["CMUX_MOBILE_CHIEF_SESSION"] = chiefSession }
        if let chiefSocket, !chiefSocket.isEmpty { environment["CMUX_MOBILE_CHIEF_SOCKET"] = chiefSocket }
        if browserHosts { environment["CMUX_MOBILE_BROWSER_HOSTS"] = "1" }
        if surfaceHosts { environment["CMUX_MOBILE_SURFACE_HOSTS"] = "1" }
        if surfaceHosts, !simulatorSurfaces { environment["CMUX_MOBILE_SURFACE_SIMULATORS"] = "0" }
        return environment
    }

    /// The control line that hands hostd an access token (never logged).
    public static func tokenLine(_ token: String) -> Data {
        line(["type": "token", "token": token])
    }

    /// The control line that tells hostd where the app's acpmux listens.
    public static func acpmuxLine(url: URL, token: String) -> Data {
        line(["type": "acpmux", "url": url.absoluteString, "token": token])
    }

    /// The control line that hands hostd each paired phone's own acpmux credential, by phone
    /// device id (`phone_credentials`): that phone's acpmux channel presents it, so its
    /// Full-access setting can cover it. Carries secrets: stdin only, never logged.
    public static func phoneCredentialsLine(_ credentials: [String: String]) -> Data {
        anyLine(["type": "phone_credentials", "credentials": credentials])
    }

    /// The control line that tells hostd which phones this Mac approved, and
    /// which identity keys the user refused (`pairing.rs`).
    public static func devicesLine(_ devices: MobileHostPairedDevices) -> Data {
        anyLine([
            "type": "devices",
            "devices": devices.hostdDevices.map {
                ["id": $0.id, "identity_key": $0.identityKey, "approval_key": $0.approvalKey]
            },
            "denied": devices.denied.map { ["id": $0.id, "identity_key": $0.identityKey] },
        ])
    }

    /// This Mac's identity key for hostd (`mac_identity`, cmux-next-ios PROTOCOL.md
    /// "Mac identity"). Carries the private key: stdin only, never logged.
    public static func macIdentityLine(_ identity: MobileHostMacIdentity) -> Data {
        line(["type": "mac_identity", "private_key": MobileHostMacIdentity.hex(identity.privateKey),
              "public_key": MobileHostMacIdentity.hex(identity.publicKey)])
    }

    /// The control line that ends a removed phone's live links.
    public static func dropPhoneLine(_ phoneDeviceID: String) -> Data {
        line(["type": "drop_phone", "phone_device_id": phoneDeviceID])
    }

    /// The answer to `need_browser` `request`: the browser host listens on
    /// `127.0.0.1:port` and admits the hello that carries `secret` (never logged).
    public static func browserLine(request: UInt64, port: UInt16, secret: String) -> Data {
        anyLine(["type": "browser", "request": request, "addr": "127.0.0.1:\(port)", "secret": secret])
    }

    /// No browser host for `request`.
    public static func browserFailedLine(request: UInt64, reason: String) -> Data {
        anyLine(["type": "browser_failed", "request": request, "reason": reason])
    }

    /// The browser host of `tab` exited.
    public static func browserGoneLine(tab: String) -> Data {
        line(["type": "browser_gone", "tab": tab])
    }

    /// The answer to `need_surface` `request`: the surface source listens on
    /// `127.0.0.1:port` and admits the `sf/1` hello that carries `secret` (never logged).
    public static func surfaceLine(request: UInt64, port: UInt16, secret: String) -> Data {
        anyLine(["type": "surface", "request": request, "addr": "127.0.0.1:\(port)", "secret": secret])
    }

    /// No surface source for `request`.
    public static func surfaceFailedLine(request: UInt64, reason: String) -> Data {
        anyLine(["type": "surface_failed", "request": request, "reason": reason])
    }

    /// The surface source of `tab` ended.
    public static func surfaceGoneLine(tab: String) -> Data {
        line(["type": "surface_gone", "tab": tab])
    }

    static func anyLine(_ object: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        data.append(0x0A)
        return data
    }

    static func line(_ object: [String: String]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        data.append(0x0A)
        return data
    }
}
