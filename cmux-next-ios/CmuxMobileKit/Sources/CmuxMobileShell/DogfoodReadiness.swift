#if DEBUG && os(iOS)
import CmuxMobileAuth
import CmuxMobileLive
import CmuxMobileModel
import Foundation
import OSLog

private let log = Logger(subsystem: "dev.cmux.mobile", category: "dogfood-readiness")

/// DEBUG only (compiled out of Release, Production and the shipping configurations): the
/// end-of-task hand-off's proof that this install is signed in and paired
/// (`cmux-next-ios/scripts/review.sh`, checked by `scripts/handoff_receipt.py`).
///
/// A launch whose environment has `CMUX_DOGFOOD_READINESS_NONCE` writes a receipt into the
/// app's data container once the account's session answered an authenticated call to the
/// mobile service (`GET /v1/me/macs`), and writes it again while pairing with the focused Mac
/// finishes. It holds no secret: the launch's nonce, the client id the launcher chose, this
/// build's identity, the signed-in account, how the session started (`auto_login` when the
/// launch carried credentials, else `restored`: the app's own Keychain session) and the
/// focused Mac with whether its link is paired and connected, and, once it is, how the link travels
/// (``Route``: transport, path, and whether the peer is a tailnet address). The launcher copies it off the
/// phone (`devicectl device copy from`) or the simulator's container; a receipt from an
/// earlier launch is deleted first, so it never answers this one. The same keys as the
/// classic app's receipt (`ios/CmuxiOS/Sources/CmuxiOSAuth/DogfoodReadinessReceipt.swift`), plus
/// the phone's own device ids (`phone_device_ids`), which the Mac lists it by.
///
/// A launch that resolves signed out writes a signed-out receipt instead (`signed_in: false`,
/// `session_source: "signed_out"`, no account): the hand-off's `--no-auth` proof that the app sits
/// at the welcome screen. A launch that then signs in replaces it with the signed-in one.
///
/// It only observes: sign-in and its persistence are the app's own (`CmuxMobileAuthModel.live`,
/// the Keychain token store and `AuthCoordinator`'s restore), the same code a Release build runs.
struct DogfoodReadiness {
    static let relativePath = "Library/Application Support/cmux-dogfood/readiness.json"
    /// How long a launch keeps writing (pairing a fresh code can take a minute on a slow network).
    static let window: Duration = .seconds(180)

    struct PairedMac: Encodable, Equatable {
        let id: String
        let name: String
        /// The link to this Mac is paired (the Mac accepted this phone) and connected.
        let linked: Bool
        /// How the linked link travels (``Route``); absent while not linked. `transport`: `wireguard` or
        /// `webrtc`; `path`: `direct-lan`, `direct-wan`, `direct`, `turn`, `turn-tls` or `none`; `tailnet`: the
        /// peer is a tailnet or CGNAT address. `handoff_receipt.py check` names them in its verdict.
        var transport: String? = nil
        var path: String? = nil
        var tailnet: Bool? = nil
    }

    /// How the link to the focused Mac travels, from the link controller's phase (transport, path) and the
    /// Rust link's peer scope. The person's iPhone and Mac may both run Tailscale, so a dev link at home can
    /// ride the tailnet, which no user without Tailscale gets: the hand-off says so
    /// (`handoff_receipt.py --forbid-tailnet`).
    struct Route: Equatable {
        let transport: String
        let path: String
        let tailnet: Bool

        /// `transport`: a `TransportKind` raw value (`wireguard`, `webrtc`); `path`: a `LinkPathKind` raw value
        /// (`direct`, `turn`, `turnTLS`, `noPath`); `peerScope`: `MacLink.peerScope` (`lan`, `tailnet`, `wan`, or
        /// empty). A direct path is `direct-lan` on this network, `direct-wan` routed (the internet, a tailnet,
        /// CGNAT; `tailnet` tells them apart), `direct` with no peer address.
        init(transport: String, path: String, peerScope: String) {
            self.transport = transport
            switch path {
            case "direct": self.path = ["lan": "direct-lan", "tailnet": "direct-wan", "wan": "direct-wan"][peerScope] ?? "direct"
            case "turn": self.path = "turn"
            case "turnTLS": self.path = "turn-tls"
            default: self.path = "none"
            }
            tailnet = path == "direct" && peerScope == "tailnet"
        }

        /// The connected link's route, nil while the controller is not connected.
        @MainActor
        static func of(_ link: LinkController) -> Route? {
            guard case .connected(let transport, let path, _) = link.phase else { return nil }
            return Route(transport: transport.rawValue, path: path.rawValue, peerScope: link.link?.peerScope ?? "")
        }
    }

    struct Body: Encodable, Equatable {
        var schema = 1
        let nonce: String
        let client_id: String
        let bundle_id: String
        let dev_tag: String
        let git_sha: String
        let api_base_url: String
        /// The Cloud service this launch uses (`CloudBackendOverride.cloudService`): the tag's
        /// `CMUX_NEXT_CLOUD_BACKEND` when the hand-off passed one (`review.sh --backend`), else the build's.
        let cloud_backend: String
        /// The cloud data space this build's requests carry (`X-Cmux-Build-Space`): `dev:<slug>` for a tagged
        /// dev build, empty for the default space, `unusable` for a dev build with no usable tag. The hand-off
        /// requires its tagged Mac's space (`handoff_receipt.py --build-space`).
        let build_space: String
        let account_email: String
        let user_id: String
        let signed_in: Bool
        let session_source: String
        let phone_device_ids: [String]
        let paired_macs: [PairedMac]
        let written_at: String
    }

    /// The focused Mac as the coordinator sees it.
    struct Focus: Equatable {
        let id: String
        let paired: Bool
        let connected: Bool
        var route: Route? = nil
    }

    let environment: [String: String]
    let bundleID: String
    let info: [String: Any]
    let defaults: UserDefaults
    /// The build space as the receipt names it (``Body/build_space``): the one the app's requests use.
    let buildSpace: String

    init(environment: [String: String] = ProcessInfo.processInfo.environment, bundle: Bundle = .main, buildSpace: String = "") {
        self.init(environment: environment, bundleID: bundle.bundleIdentifier ?? "", info: bundle.infoDictionary ?? [:],
                  buildSpace: buildSpace)
    }

    init(environment: [String: String], bundleID: String, info: [String: Any], defaults: UserDefaults = .standard,
         buildSpace: String = "") {
        self.environment = environment
        self.bundleID = bundleID
        self.info = info
        self.defaults = defaults
        self.buildSpace = buildSpace
    }

    /// The receipt's build space for the app's own state: what `CMUX_BUILD_SPACE` children get.
    @MainActor
    init(auth: CmuxMobileAuthModel) {
        self.init(buildSpace: auth.buildSpace.childEnvironmentValue ?? "")
    }

    /// The Cloud service this launch uses, as the receipt names it (DEBUG builds only write one).
    var cloudBackend: String {
        CloudBackendOverride.cloudService(environment: environment, infoValue: info["CmuxMobileCloudAPIBase"] as? String,
                                          defaults: defaults, debug: true)?.url.absoluteString ?? ""
    }

    /// The launcher asked for a receipt.
    var nonce: String? {
        guard let nonce = environment["CMUX_DOGFOOD_READINESS_NONCE"], !nonce.isEmpty else { return nil }
        return nonce
    }

    /// The build's tag, without the bundle-id dot Info.plist `CmuxMobileTag` carries (".my-tag").
    var devTag: String {
        let raw = info["CmuxMobileTag"] as? String ?? ""
        return raw.hasPrefix(".") ? String(raw.dropFirst()) : raw
    }

    /// `auto_login` when this launch carried the account's credentials or a session made elsewhere
    /// (`CMUX_MOBILE_STACK_REFRESH_TOKEN`, a fleet step's `--sign-in agent` session), else `restored`.
    var sessionSource: String {
        let injected = ["CMUX_MOBILE_STACK_EMAIL", "CMUX_MOBILE_STACK_REFRESH_TOKEN"]
        return injected.contains { !(environment[$0] ?? "").isEmpty } ? "auto_login" : "restored"
    }

    /// The receipt for one moment of this launch. `macs` is the account's Macs from the service
    /// (their names); `focus` the coordinator's focused Mac.
    func body(nonce: String, apiBase: URL, email: String, userID: String, macs: [LiveAPI.Mac],
              focus: Focus?, phoneDeviceIDs: [String] = [], now: Date) -> Body {
        let paired = focus.map { focus -> [PairedMac] in
            let linked = focus.paired && focus.connected
            let route = linked ? focus.route : nil
            return [PairedMac(id: focus.id, name: macs.first { $0.deviceId == focus.id }?.name ?? "", linked: linked,
                              transport: route?.transport, path: route?.path, tailnet: route?.tailnet)]
        } ?? []
        return Body(
            nonce: nonce,
            client_id: environment["CMUX_DOGFOOD_CLIENT_ID"] ?? "",
            bundle_id: bundleID,
            dev_tag: devTag,
            git_sha: info["CmuxMobileSourceCommit"] as? String ?? "",
            api_base_url: apiBase.absoluteString,
            cloud_backend: cloudBackend,
            build_space: buildSpace,
            account_email: email.lowercased(),
            user_id: userID,
            signed_in: true,
            session_source: sessionSource,
            phone_device_ids: phoneDeviceIDs,
            paired_macs: paired,
            written_at: ISO8601DateFormatter().string(from: now)
        )
    }

    /// The receipt of a launch that resolved signed out: no account, no Macs.
    func signedOutBody(nonce: String, apiBase: URL?, now: Date) -> Body {
        Body(
            nonce: nonce,
            client_id: environment["CMUX_DOGFOOD_CLIENT_ID"] ?? "",
            bundle_id: bundleID,
            dev_tag: devTag,
            git_sha: info["CmuxMobileSourceCommit"] as? String ?? "",
            api_base_url: apiBase?.absoluteString ?? "",
            cloud_backend: cloudBackend,
            build_space: buildSpace,
            account_email: "",
            user_id: "",
            signed_in: false,
            session_source: "signed_out",
            phone_device_ids: [],
            paired_macs: [],
            written_at: ISO8601DateFormatter().string(from: now)
        )
    }

    static func encode(_ body: Body) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(body)
    }

    static var url: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent(relativePath)
    }

    /// Starts writing when the launcher asked for a receipt; returns the task (nil otherwise).
    @MainActor
    @discardableResult
    func start(auth: CmuxMobileAuthModel, live: LiveCoordinator, apiBase: URL) -> Task<Void, Never>? {
        guard let nonce else { return nil }
        let url = Self.url
        return Task { @MainActor in
            await Self.write(nil, to: url)  // an earlier launch's receipt never answers this one
            // In the app's own space, as its Mac list is read (a dev build's tag space).
            let api = LiveAPI(baseURL: apiBase, buildSpace: auth.buildSpace) { force in try await auth.serviceAccessToken(forceRefresh: force) }
            let clock = ContinuousClock()
            let deadline = clock.now + Self.window
            var last: Body?
            // The authenticated call: the account's Macs, read again when the focused Mac is not
            // among them yet (a Mac paired this launch). The focus is read every second for the whole
            // window, never stopping at the first linked Mac: a launch that names a Mac to focus may
            // still be on the Mac it remembered when it first links.
            var macs: [LiveAPI.Mac]?
            while !Task.isCancelled, clock.now < deadline {
                if auth.isSignedIn, let user = auth.user, let email = user.email {
                    let unnamed = live.focusedMacID.map { id in !(macs ?? []).contains { $0.deviceId == id } } ?? false
                    if macs == nil || unnamed {
                        macs = (try? await api.myMacs()) ?? macs
                    }
                    if let macs {
                        let focus = live.focusedMacID.map {
                            Focus(id: $0, paired: live.pairingState == .paired, connected: live.link.phase.isConnected,
                                  route: Route.of(live.link))
                        }
                        let next = body(nonce: nonce, apiBase: apiBase, email: email, userID: user.id, macs: macs,
                                        focus: focus, phoneDeviceIDs: live.deviceIDs, now: Date())
                        if last == nil || next.paired_macs != last?.paired_macs {
                            await Self.write(next, to: url)
                            last = next
                            log.info("readiness receipt: \(next.session_source, privacy: .public), \(next.paired_macs.count) Mac(s), linked \(next.paired_macs.first?.linked == true), path \(next.paired_macs.first?.path ?? "-", privacy: .public)")
                        }
                    }
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// The launch resolved signed out: writes the signed-out receipt when the launcher asked for one.
    @MainActor
    func writeSignedOut(apiBase: URL?) {
        guard let nonce else { return }
        let body = signedOutBody(nonce: nonce, apiBase: apiBase, now: Date())
        Task { @MainActor in
            await Self.write(body, to: Self.url)
            log.info("readiness receipt: signed out")
        }
    }

    /// Writes (or with nil removes) the receipt off the main actor.
    private static func write(_ body: Body?, to url: URL) async {
        let data = body.flatMap { try? encode($0) }
        await Task.detached(priority: .utility) {
            let files = FileManager.default
            guard let data else {
                try? files.removeItem(at: url)
                return
            }
            do {
                try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch {
                log.error("readiness receipt not written: \(String(describing: type(of: error)), privacy: .public)")
            }
        }.value
    }
}
#endif
