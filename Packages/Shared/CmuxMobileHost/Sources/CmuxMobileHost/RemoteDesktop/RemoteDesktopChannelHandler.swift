import CmuxMobileLink
public import CmuxLink
public import CmuxMobileWire
import CmuxRemoteDesktop

/// Serves `rd` channels (lane C3, c3-rd.md): validates the target, checks
/// Screen Recording, the VNC policy and the target's existence, answers
/// `channel.opened`, asks the person at the Mac, then streams the target
/// as rd datagrams and injects input only in control mode while the
/// session gate is open. Register it in
/// `MobileHost(handlers: MobileChannelHandlers(channels: [.rd: ...]))`.
public struct RemoteDesktopChannelHandler: MobileChannelHandler {
    public let sources: any RemoteDesktopSources
    public let permissions: any RemoteDesktopPermissions
    public let consent: any RemoteDesktopConsent
    public let indicator: any RemoteDesktopIndicator
    public let policy: RemoteDesktopPolicy
    public let clock: LinkClock

    public init(sources: any RemoteDesktopSources, permissions: any RemoteDesktopPermissions, consent: any RemoteDesktopConsent,
                indicator: any RemoteDesktopIndicator, policy: RemoteDesktopPolicy = RemoteDesktopPolicy(),
                clock: LinkClock = .continuous) {
        self.sources = sources
        self.permissions = permissions
        self.consent = consent
        self.indicator = indicator
        self.policy = policy
        self.clock = clock
    }

    public func serve(_ channel: MobileChannel, open: ChannelOpenFrame, principal: MobileDevicePrincipal,
                      gate: MobileSessionGate) async {
        let params: RemoteDesktopChannelParams
        do {
            params = try RemoteDesktopChannelParams(params: open.params)
        } catch {
            await channel.refuse(code: "validation.invalid", message: error.message)
            return
        }
        guard await gate.isOpen else {
            await channel.refuse(code: "auth.revoked", message: "this device was revoked")
            return
        }
        if case .vnc(let address) = params.target {
            guard policy.vnc.permits(address) else {
                await channel.refuse(code: "rd.vnc_not_allowed", message: "this Mac does not proxy VNC to \(address.host)")
                return
            }
        } else if await !permissions.isGranted(.screenRecording) {
            await channel.refuse(code: "rd.permission_denied", message: "Screen Recording is off for cmux on this Mac",
                                 details: .object(["permission": .string(RemoteDesktopPermission.screenRecording.rawValue)]))
            return
        }
        let info: DesktopTargetInfo
        do {
            info = try await sources.describe(params.target)
        } catch let error as RemoteDesktopSourceError {
            await channel.refuse(code: error.code, message: "\(error)", retryable: error.isRetryable)
            return
        } catch {
            await channel.refuse(code: "rd.unavailable", message: "\(error)", retryable: true)
            return
        }
        let session = RemoteDesktopSession(channel: channel, params: params, info: info, install: principal.install, gate: gate,
                                           handler: self)
        await session.run()
    }
}
