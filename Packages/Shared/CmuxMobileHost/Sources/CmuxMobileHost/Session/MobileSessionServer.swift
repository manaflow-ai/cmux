import CmuxLink
import CmuxMobileWire
import Foundation

/// Serves one link session: the hello on the session channel (A0 channel 0),
/// then one service per channel (b5-mac-host.md section 2). Nothing is served
/// before the device proof verifies.
actor MobileSessionServer {
    static let sessionStream = "cmux.mobile/session"

    private enum Admission {
        case none
        case pending([CheckedContinuation<MobileDevicePrincipal?, Never>])
        case admitted(MobileDevicePrincipal)
        case denied
    }

    let session: LinkSession
    private let context: MobileHostContext
    private let attestation: CarrierAttestation?
    private var admission = Admission.none
    private var usedChannelIDs: Set<UInt32> = [0]
    private var channels: [UInt32: MobileChannel] = [:]
    private var tasks: [Task<Void, Never>] = []
    private var revoked = false

    init(session: LinkSession, context: MobileHostContext, attestation: CarrierAttestation? = nil) {
        self.session = session
        self.context = context
        self.attestation = attestation
    }

    var principal: MobileDevicePrincipal? {
        if case .admitted(let principal) = admission { return principal }
        return nil
    }

    /// Serves until the link session closes.
    func run() async {
        for await link in await session.incomingChannels() {
            let task = Task { await self.serve(link) }
            tasks.append(task)
        }
        for task in tasks { task.cancel() }
    }

    /// The device was revoked: every channel gets `auth.revoked`, then the session closes.
    func revoke() async {
        revoked = true
        for channel in channels.values { await channel.close(code: "auth.revoked", message: "this device was revoked") }
        await session.close()
    }

    // MARK: Channels

    private func serve(_ link: LinkChannel) async {
        if link.stream == Self.sessionStream, case .none = admission {
            admission = .pending([])
            await serveSessionChannel(link)
            return
        }
        guard let (channel, first) = try? await MobileChannel.accept(link) else {
            await link.close()
            return
        }
        guard let principal = await awaitAdmission() else {
            await channel.refuse(code: "auth.unauthenticated", message: "send hello with a device proof first")
            return
        }
        guard case .channelOpen(let open)? = try? MobileFrame(value: first), open.channel == channel.id else {
            await channel.refuse(code: "validation.invalid", message: "the first record must be channel.open")
            return
        }
        guard open.channel % 2 == 1, !usedChannelIDs.contains(open.channel) else {
            await channel.refuse(code: "validation.invalid", message: "phones open odd, unused channel ids")
            return
        }
        guard !revoked else {
            await channel.refuse(code: "auth.revoked", message: "this device was revoked")
            return
        }
        usedChannelIDs.insert(open.channel)
        channels[open.channel] = channel
        await context.serve(channel, open: open, principal: principal)
        channels[open.channel] = nil
    }

    private func awaitAdmission() async -> MobileDevicePrincipal? {
        switch admission {
        case .none, .denied: return nil
        case .admitted(let principal): return principal
        case .pending:
            return await withCheckedContinuation { continuation in
                switch admission {
                case .pending(var waiters):
                    waiters.append(continuation)
                    admission = .pending(waiters)
                case .admitted(let principal):
                    continuation.resume(returning: principal)
                case .none, .denied:
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func settle(_ result: MobileDevicePrincipal?) {
        guard case .pending(let waiters) = admission else { return }
        admission = result.map { .admitted($0) } ?? .denied
        for waiter in waiters { waiter.resume(returning: result) }
    }

    // MARK: Hello

    private func serveSessionChannel(_ link: LinkChannel) async {
        guard let (channel, first) = try? await MobileChannel.accept(link), channel.id == 0 else {
            settle(nil)
            await link.close()
            await session.close()
            return
        }
        switch await admit(first) {
        case .success(let (principal, ok)):
            guard (try? await channel.send(frame: .helloOK(ok))) != nil else {
                settle(nil)
                return
            }
            settle(principal)
            await context.register(self, install: principal.install)
            // The session channel carries nothing after hello.ok; drain until close.
            drain: while true {
                if case .closed = await channel.receive() { break drain }
            }
        case .failure(let error):
            settle(nil)
            try? await channel.send(frame: .error(ErrorFrame(code: error.code, message: error.message, retryable: false)))
            await channel.finish()
            await session.close()
        }
    }

    private func admit(_ value: JSONValue) async -> Result<(MobileDevicePrincipal, HelloOKFrame), MobileAuthFailure> {
        guard case .hello(let hello)? = try? MobileFrame(value: value) else {
            return .failure(MobileAuthFailure(code: "proto.hello_required", message: "the first frame must be hello"))
        }
        guard hello.min <= 1, hello.max >= 1 else {
            return .failure(MobileAuthFailure(code: "proto.version_unsupported", message: "this host speaks version 1"))
        }
        let request = DeviceAuthRequest(client: hello.client, proof: DeviceProof(json: value["auth"]),
                                        sessionID: session.sessionID, attestation: attestation)
        switch await context.authorizer.authorize(request) {
        case .success(let principal):
            let caps = context.configuration.caps.filter { hello.caps.contains($0) }
            let ok = HelloOKFrame(version: 1, caps: caps, serverTime: Int64(Date().timeIntervalSince1970 * 1000),
                                  maxFrame: context.configuration.maxFrame)
            return .success((principal, ok))
        case .failure(let failure):
            return .failure(failure)
        }
    }
}
