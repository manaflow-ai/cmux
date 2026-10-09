import CmuxBrowserStream
public import CmuxLink
public import CmuxMobileLink
public import CmuxMobileWire

/// Serves `simulator` channels (c14-web.md section 6): attaches to a booted
/// simulator through `SimulatorCaptureHost` and runs C2's browser channel
/// session over it, with navigation refused and input only while the
/// session gate is open.
public struct SimulatorChannelHandler: MobileChannelHandler {
    public let simulators: any SimulatorCaptureHost
    public let clock: LinkClock

    public init(simulators: any SimulatorCaptureHost, clock: LinkClock = .continuous) {
        self.simulators = simulators
        self.clock = clock
    }

    public func serve(_ channel: MobileChannel, open: ChannelOpenFrame, principal: MobileDevicePrincipal,
                      gate: MobileSessionGate) async {
        let params: BrowserChannelParams
        do {
            params = try BrowserChannelParams(params: open.params, kind: .simulator)
        } catch {
            await channel.refuse(code: "validation.invalid", message: error.message)
            return
        }
        guard await gate.isOpen else {
            await channel.refuse(code: "auth.revoked", message: "this device was revoked")
            return
        }
        let udid = params.target.id
        let known = (try? await simulators.simulators()) ?? []
        guard let info = known.first(where: { $0.udid.caseInsensitiveCompare(udid) == .orderedSame && $0.state == .booted }) else {
            await channel.refuse(code: "simulator.not_found", message: "no booted simulator \(udid) on this Mac")
            return
        }
        let device: any SimulatorAttachment
        do {
            device = try await simulators.attach(SimulatorAttachRequest(udid: info.udid, install: principal.install,
                                                                        screen: params.screen, codecs: params.codecs))
        } catch SimulatorCaptureError.notFound {
            await channel.refuse(code: "simulator.not_found", message: "no booted simulator \(udid) on this Mac")
            return
        } catch {
            await channel.refuse(code: "simulator.unavailable", message: "\(error)", retryable: true)
            return
        }
        let page = SimulatorPageAttachment(device: device, name: info.name, udid: info.udid)
        let session = BrowserChannelSession(channel: channel, params: params, attachment: page, gate: gate,
                                            policy: .none, clock: clock)
        await session.run()
    }
}
