import AppKit
import CmuxNextDesign
import CmuxNextDevices
import Foundation

/// What the home page reads of the device hub: the hub (while signed in),
/// this Mac as a host, and whether the build has a hub at all.
@MainActor
public struct MacScreenHomeDevices {
    let box: MacScreenHubBox
    let hubHost: MacScreenHubHost
    let store: MacScreenStore

    init(pages: MacScreenPages) {
        box = pages.hubBox
        hubHost = pages.hubHost
        store = pages.store
    }
}

/// What the home page shows, as values: the page builds its rows from this
/// and again only when it changes (the snapshot boundary: rows never hold
/// the hub or the host).
struct MacScreenHomeSnapshot: Equatable {
    /// One of the user's devices that shares Mac Screen.
    struct Device: Equatable {
        var id: String
        var name: String
        /// nil: a record made before platforms (a Mac).
        var platform: DevicePlatform?
        var online: Bool
        var macScreenShared: Bool
        /// This Mac's access to it: only whether the host blocks this Mac shows (the hub refuses without a prompt).
        var access: MacScreenAccess
        /// The hub's online word is current (this Mac's own hub link is up); false: `online` may be stale.
        var onlineKnown = true
        var lastSeen: Date?
        /// Whether the device allows this Mac's connections, from Settings › Devices' per-machine switch
        /// (``MacScreenRemoteAccess``); nil while that switch is not known here (the row's menu then offers no Off).
        var allowsThisMac: Bool?

        init(id: String, name: String, platform: DevicePlatform? = .macos, online: Bool, macScreenShared: Bool,
             access: MacScreenAccess, onlineKnown: Bool = true, lastSeen: Date? = nil, allowsThisMac: Bool? = nil) {
            self.id = id
            self.name = name
            self.platform = platform
            self.online = online
            self.macScreenShared = macScreenShared
            self.access = access
            self.onlineKnown = onlineKnown
            self.lastSeen = lastSeen
            self.allowsThisMac = allowsThisMac
        }

        var isPhone: Bool { platform == .ios }

        /// Offline counts only while this Mac's hub link is up; until then the hub's word may be stale and the
        /// row stays openable (the pane's Connect card says what it finds).
        var reachable: Bool { online || !onlineKnown }

        /// The row's one action works: reachable, sharing and not blocking this Mac.
        var connectable: Bool { reachable && macScreenShared && access.allowsRequests }
    }

    /// Your Devices: a note (signed out, loading, none shared) or the list.
    enum Devices: Equatable {
        case note(String)
        /// Signed out of cmux: the note, then the shared Sign In button (``SignInButton``).
        case signedOut(String)
        case list([Device])

        /// The note text this state shows (signed out or a note), or nil for the list.
        var note: String? {
            switch self {
            case let .note(text), let .signedOut(text): text
            case .list: nil
            }
        }
    }

    /// Allow Mac Screen on This Mac.
    struct Sharing: Equatable {
        var isSharing: Bool
        var busy: Bool
        var screenRecordingGranted: Bool
        var accessibilityGranted: Bool
        var session: MacScreenHubHost.Session?
        var lastError: String?
        var showFirstUse: Bool

        init(isSharing: Bool, busy: Bool, screenRecordingGranted: Bool, accessibilityGranted: Bool,
             session: MacScreenHubHost.Session? = nil, lastError: String? = nil, showFirstUse: Bool = false) {
            self.isSharing = isSharing
            self.busy = busy
            self.screenRecordingGranted = screenRecordingGranted
            self.accessibilityGranted = accessibilityGranted
            self.session = session
            self.lastError = lastError
            self.showFirstUse = showFirstUse
        }
    }

    struct Keyboard: Equatable {
        var enabled: Bool
        var needsAccessibility: Bool
    }

    var devices: Devices?
    var sharing: Sharing?
    var keyboard: Keyboard?
    /// The type scale the rows were built at (`MacScreenType.sizes`).
    var typeSizes = MacScreenType.sizes
    /// The look of Allow Mac Screen on This Mac (Debug Settings `macScreen.sharingLook`).
    var sharingLook = MacScreenTunables.sharingLook.value
    /// The look of Your Devices' rows (Debug Settings `macScreen.devicesLook`).
    var devicesLook = MacScreenTunables.devicesLook.value

    /// The hosts listed, whose permission lists the page reads.
    var deviceIDs: [String] {
        guard case let .list(devices) = devices else { return [] }
        return devices.map(\.id)
    }

    /// A snapshot of given values (tests and galleries draw the page from it with `MacScreenHomeView.build`).
    init(devices: Devices? = nil, sharing: Sharing? = nil, keyboard: Keyboard? = nil, sharingLook: MacScreenSharingLook,
         devicesLook: MacScreenDevicesLook = .connect) {
        self.devices = devices
        self.sharing = sharing
        self.keyboard = keyboard
        self.sharingLook = sharingLook
        self.devicesLook = devicesLook
    }

    /// Reads `home`'s models (under Observation, so a change of any value read here redraws the page).
    @MainActor
    init(home: MacScreenHomeView) {
        if let source = home.devices {
            if let hub = source.box.hub {
                // One row per physical device: this Mac's other builds (NIGHTLY, DEV) and stale records are not remotes.
                let listed = Self.listed(hub.remoteDevices)
                if listed.isEmpty {
                    devices = .note(hub.status == .ready || hub.status == .idle
                        ? L.t("macScreen.home.noOtherDevices", "Your other devices show here once they are signed in to cmux.")
                        : L.t("macScreen.home.devicesLoading", "Loading your devices…"))
                } else {
                    let remote = home.actions.remoteAccess
                    devices = .list(listed.map { device in
                        Self.device(device, access: MacScreenAccess(hub.scope(host: device.id, viewer: hub.identity.id)),
                                    hubConnected: hub.connection == .connected,
                                    allowsThisMac: remote?.allows(device.id, device.name))
                    })
                }
                if hub.thisDevice != nil {
                    let hubHost = source.hubHost
                    sharing = Sharing(isSharing: hubHost.isSharing, busy: hubHost.busy,
                                      screenRecordingGranted: home.host.screenRecordingGranted,
                                      accessibilityGranted: home.host.accessibilityGranted,
                                      session: hubHost.session, lastError: hubHost.lastError,
                                      showFirstUse: Self.showsFirstUse(store: source.store, isSharing: hubHost.isSharing))
                }
            } else {
                devices = source.box.startupMessage.map(Devices.note) ?? Self.setupDevices(configured: source.box.configured)
            }
        }
        if let shortcuts = home.systemShortcuts {
            keyboard = Keyboard(enabled: shortcuts.enabled, needsAccessibility: shortcuts.needsAccessibility)
        }
    }

    /// One hub device as the page shows it.
    static func device(_ device: HubDevice, access: MacScreenAccess, hubConnected: Bool, allowsThisMac: Bool? = nil) -> Device {
        Device(id: device.id, name: device.name, platform: device.platform, online: device.online,
               macScreenShared: device.macScreenShared, access: access, onlineKnown: hubConnected, lastSeen: device.lastSeenAt,
               allowsThisMac: allowsThisMac)
    }

    /// Whether the page opens with the first-use steps: until this Mac has shared or viewed once.
    @MainActor
    static func showsFirstUse(store: MacScreenStore, isSharing: Bool) -> Bool {
        !store.hasUsedBefore && !isSharing
    }

    /// The devices the page lists, from ``DeviceHub/remoteDevices`` (one per physical device): every other
    /// computer (Mac, Linux, Windows), online or not, sharing or not, so the page can say how to reach it; a
    /// phone only when it shares, since its row could only say to turn on what a phone cannot.
    static func listed(_ devices: [HubDevice]) -> [HubDevice] {
        devices.filter { $0.platform != .ios || $0.macScreenShared }
    }

    /// What the home page says while Mac Screen cannot work: it needs a
    /// signed-in cmux account, and a DEV build's Device Hub Address override
    /// (Settings › Development) must be valid when set.
    static func setupDevices(configured: Bool) -> Devices {
        guard configured else {
            return .note(L.t("macScreen.home.invalidHubAddress", "Mac Screen works through the device hub. The Device Hub Address in Settings › Development is not a valid web address; fix it, or clear it to use the built-in hub."))
        }
        return .signedOut(L.t("macScreen.home.devicesSignIn", "Sign in to cmux to see your other Macs here."))
    }
}
