import CmuxBrowserStream
public import CmuxLink
public import CmuxMobileLink
public import CmuxMobileWire

/// Serves `browser` channels (lane C2, c2-browser-stream.md): attaches to
/// the Mac tab through `BrowserPageHost`, streams its video as rd
/// datagrams (on the paired datagram lane when present, else on the
/// channel), and applies rb input, navigation, history and clipboard only
/// while the session gate is open. Register it in
/// `MobileHost(handlers: MobileChannelHandlers(channels: [.browser: ...]))`.
public struct BrowserChannelHandler: MobileChannelHandler {
    public let pages: any BrowserPageHost
    public let policy: BrowserNavigationPolicy
    public let clock: LinkClock

    public init(pages: any BrowserPageHost, policy: BrowserNavigationPolicy = BrowserNavigationPolicy(),
                clock: LinkClock = .continuous) {
        self.pages = pages
        self.policy = policy
        self.clock = clock
    }

    public func serve(_ channel: MobileChannel, open: ChannelOpenFrame, principal: MobileDevicePrincipal,
                      gate: MobileSessionGate) async {
        let params: BrowserChannelParams
        do {
            params = try BrowserChannelParams(params: open.params)
        } catch {
            await channel.refuse(code: "validation.invalid", message: error.message)
            return
        }
        guard await gate.isOpen else {
            await channel.refuse(code: "auth.revoked", message: "this device was revoked")
            return
        }
        let attachment: any BrowserPageAttachment
        do {
            attachment = try await pages.attach(BrowserAttachRequest(tab: params.tab, install: principal.install,
                                                                     screen: params.screen, codecs: params.codecs))
        } catch BrowserPageError.tabNotFound {
            await channel.refuse(code: "browser.tab_not_found", message: "no browser tab \(params.tab) on this Mac")
            return
        } catch {
            await channel.refuse(code: "browser.unavailable", message: "\(error)", retryable: true)
            return
        }
        let session = BrowserChannelSession(channel: channel, params: params, attachment: attachment, gate: gate,
                                            policy: policy, clock: clock)
        await session.run()
    }
}
