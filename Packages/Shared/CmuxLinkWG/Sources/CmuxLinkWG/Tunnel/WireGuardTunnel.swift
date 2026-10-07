/// One WireGuard session with one peer, sans-IO (the shape of boringtun's
/// `Tunn`): datagrams and time go in, datagrams and plaintext come out. The
/// owning transport serializes every call.
struct WireGuardTunnel {
    static let stagedLimit = 1024

    let peer: WireGuardPublicKey
    let timers: WireGuardTimers
    private let handshake: WireGuardHandshake
    private let source: WireGuardHandshakeSource
    private var pending: WireGuardInitiation?
    private var handshakeStartedAt: Duration?
    private var current: WireGuardKeypair?
    private var previous: WireGuardKeypair?
    /// A keypair this end answered, until the initiator's first data packet.
    private var next: WireGuardKeypair?
    private var latestTimestamp: TAI64N?
    /// Plaintext waiting for a usable keypair.
    private var staged: [[UInt8]] = []
    /// When the peer's last data packet with content arrived and nothing was
    /// sent since (the passive keepalive is due KEEPALIVE after it).
    private var keepaliveDueFrom: Duration?
    /// First data packet sent since the last authenticated receive.
    private var unansweredSince: Duration?

    init(identity: WireGuardPrivateKey, peer: WireGuardPublicKey, timers: WireGuardTimers, source: WireGuardHandshakeSource) {
        self.peer = peer
        self.timers = timers
        self.source = source
        handshake = WireGuardHandshake(identity: identity)
    }

    /// The local indices this tunnel answers to (for routing a datagram from
    /// a new underlay to its transport).
    var localIndices: [UInt32] {
        [current?.localIndex, previous?.localIndex, next?.localIndex, pending?.localIndex].compactMap(\.self)
    }

    var currentLocalIndex: UInt32? { current?.localIndex }

    var isHandshaking: Bool { pending != nil }

    func hasUsableSession(at now: Duration) -> Bool {
        current?.isUsable(at: now, timers: timers) ?? false
    }

    // MARK: Handshake

    /// Starts (or restarts) a handshake as initiator.
    mutating func beginHandshake(now: Duration) -> WireGuardTunnelOutput {
        var output = WireGuardTunnelOutput()
        if handshakeStartedAt == nil { handshakeStartedAt = now }
        do {
            let initiation = try handshake.makeInitiation(
                to: peer.bytes,
                localIndex: freshIndex(),
                ephemeral: source.makeEphemeral(),
                timestamp: TAI64N(date: source.now()),
                now: now
            )
            pending = initiation
            output.datagrams.append(initiation.message)
        } catch {
            output.error = .decryptFailed
        }
        return output
    }

    /// Answers an initiation the caller already authenticated and authorized
    /// (`WireGuardHandshake.consumeInitiation` plus the authorizer).
    mutating func respond(to initiation: WireGuardReceivedInitiation, now: Duration) -> WireGuardTunnelOutput {
        var output = WireGuardTunnelOutput()
        guard initiation.peer == peer else {
            output.error = .unexpectedPeer
            return output
        }
        if let latestTimestamp, initiation.timestamp <= latestTimestamp {
            output.error = .replayedInitiation
            return output
        }
        do {
            let (message, keypair) = try handshake.makeResponse(
                to: initiation, localIndex: freshIndex(), ephemeral: source.makeEphemeral(), now: now
            )
            latestTimestamp = initiation.timestamp
            next = keypair
            output.datagrams.append(message)
        } catch {
            output.error = .decryptFailed
        }
        return output
    }

    // MARK: Receive

    mutating func decapsulate(_ datagram: [UInt8], now: Duration) -> WireGuardTunnelOutput {
        guard let type = datagram.first, datagram.count >= 4, datagram[1] == 0, datagram[2] == 0, datagram[3] == 0 else {
            return WireGuardTunnelOutput(error: .malformedMessage)
        }
        switch type {
        case WireGuardProtocol.initiationType:
            do {
                return respond(to: try handshake.consumeInitiation(datagram), now: now)
            } catch let error as WireGuardTunnelError {
                return WireGuardTunnelOutput(error: error)
            } catch {
                return WireGuardTunnelOutput(error: .decryptFailed)
            }
        case WireGuardProtocol.responseType:
            return consumeResponse(datagram, now: now)
        case WireGuardProtocol.dataType:
            return receiveData(datagram, now: now)
        case WireGuardProtocol.cookieReplyType:
            // Cookie replies are not implemented (b3-webrtc-wg.md section 4).
            return WireGuardTunnelOutput()
        default:
            return WireGuardTunnelOutput(error: .malformedMessage)
        }
    }

    private mutating func consumeResponse(_ datagram: [UInt8], now: Duration) -> WireGuardTunnelOutput {
        guard let initiation = pending else { return WireGuardTunnelOutput(error: .unknownIndex) }
        do {
            let keypair = try handshake.consumeResponse(datagram, to: initiation, peer: peer.bytes, now: now)
            pending = nil
            handshakeStartedAt = nil
            previous = current
            current = keypair
            next = nil
            var output = WireGuardTunnelOutput(sessionEstablished: true)
            output.datagrams = flushStaged(now: now)
            // The responder may send only after it sees data under the new
            // keys: confirm with a keepalive when nothing else is queued.
            if output.datagrams.isEmpty, let keepalive = seal([], now: now) { output.datagrams.append(keepalive) }
            return output
        } catch let error as WireGuardTunnelError {
            return WireGuardTunnelOutput(error: error)
        } catch {
            return WireGuardTunnelOutput(error: .decryptFailed)
        }
    }

    private mutating func receiveData(_ datagram: [UInt8], now: Duration) -> WireGuardTunnelOutput {
        guard datagram.count >= WireGuardProtocol.minimumDataLength else { return WireGuardTunnelOutput(error: .malformedMessage) }
        let receiver = WireGuardProtocol.readLE32(datagram, at: 4)
        let counter = WireGuardProtocol.readLE64(datagram, at: 8)
        let slot: Slot
        if current?.localIndex == receiver { slot = .current }
        else if next?.localIndex == receiver { slot = .next }
        else if previous?.localIndex == receiver { slot = .previous }
        else { return WireGuardTunnelOutput(error: .unknownIndex) }
        guard var keypair = keypair(in: slot) else { return WireGuardTunnelOutput(error: .unknownIndex) }
        guard now - keypair.createdAt < timers.rejectAfterTime else { return WireGuardTunnelOutput(error: .sessionExpired) }
        guard keypair.replay.canAccept(counter) else { return WireGuardTunnelOutput(error: .replayedCounter) }
        let plaintext: [UInt8]
        do {
            plaintext = try keypair.receiveKey.open(datagram[WireGuardProtocol.dataHeaderLength...], counter: counter)
        } catch {
            return WireGuardTunnelOutput(error: .decryptFailed)
        }
        guard keypair.replay.accept(counter) else { return WireGuardTunnelOutput(error: .replayedCounter) }
        store(keypair, in: slot)

        var output = WireGuardTunnelOutput(plaintext: plaintext)
        unansweredSince = nil
        if slot == .next {
            previous = current
            current = next
            next = nil
            output.sessionEstablished = true
            output.datagrams = flushStaged(now: now)
        }
        if !plaintext.isEmpty, keepaliveDueFrom == nil { keepaliveDueFrom = now }
        if let current, current.isInitiator, pending == nil,
           now - current.createdAt >= timers.rejectAfterTime - timers.keepaliveTimeout - timers.rekeyTimeout {
            output.datagrams += beginHandshake(now: now).datagrams
        }
        return output
    }

    // MARK: Send

    /// Encrypts one packet, or stages it and starts a handshake when no
    /// keypair is usable.
    mutating func encapsulate(_ plaintext: [UInt8], now: Duration) -> WireGuardTunnelOutput {
        var output = WireGuardTunnelOutput()
        guard hasUsableSession(at: now), let datagram = seal(plaintext, now: now) else {
            if staged.count >= Self.stagedLimit { staged.removeFirst() }
            staged.append(plaintext)
            // A keypair this end answered becomes usable with the initiator's
            // first data packet; starting a second handshake would race it.
            if pending == nil, next == nil { output.datagrams += beginHandshake(now: now).datagrams }
            return output
        }
        output.datagrams.append(datagram)
        if let current, current.isInitiator, pending == nil,
           now - current.createdAt >= timers.rekeyAfterTime || current.sendCounter >= timers.rekeyAfterMessages {
            output.datagrams += beginHandshake(now: now).datagrams
        }
        return output
    }

    private mutating func seal(_ plaintext: [UInt8], now: Duration) -> [UInt8]? {
        guard var keypair = current, keypair.isUsable(at: now, timers: timers) else { return nil }
        let padded = plaintext + [UInt8](repeating: 0, count: (16 - plaintext.count % 16) % 16)
        let counter = keypair.sendCounter
        guard let sealed = try? keypair.sendKey.seal(padded, counter: counter) else { return nil }
        keypair.sendCounter += 1
        current = keypair
        keepaliveDueFrom = nil
        if !plaintext.isEmpty, unansweredSince == nil { unansweredSince = now }
        var datagram = [WireGuardProtocol.dataType, 0, 0, 0] + WireGuardProtocol.le32(keypair.remoteIndex)
        datagram += WireGuardProtocol.le64(counter)
        datagram += sealed
        return datagram
    }

    private mutating func flushStaged(now: Duration) -> [[UInt8]] {
        let packets = staged
        staged.removeAll()
        return packets.compactMap { seal($0, now: now) }
    }

    // MARK: Timers

    /// The earliest moment `updateTimers` has work, or nil when idle.
    func nextDeadline() -> Duration? {
        var deadlines: [Duration] = []
        if let pending { deadlines.append(pending.sentAt + timers.rekeyTimeout) }
        if let keepaliveDueFrom { deadlines.append(keepaliveDueFrom + timers.keepaliveTimeout) }
        if let unansweredSince, pending == nil {
            deadlines.append(unansweredSince + timers.keepaliveTimeout + timers.rekeyTimeout)
        }
        return deadlines.min()
    }

    mutating func updateTimers(now: Duration) -> WireGuardTunnelOutput {
        var output = WireGuardTunnelOutput()
        if let pending, now >= pending.sentAt + timers.rekeyTimeout {
            if let started = handshakeStartedAt, now - started >= timers.rekeyAttemptTime {
                self.pending = nil
                handshakeStartedAt = nil
                staged.removeAll()
                output.error = .handshakeTimeout
            } else {
                output.datagrams += beginHandshake(now: now).datagrams
            }
        }
        if let due = keepaliveDueFrom, now >= due + timers.keepaliveTimeout {
            keepaliveDueFrom = nil
            if let keepalive = seal([], now: now) { output.datagrams.append(keepalive) }
        }
        if let since = unansweredSince, pending == nil, now >= since + timers.keepaliveTimeout + timers.rekeyTimeout {
            // Data went out and nothing authenticated came back: the peer
            // may have lost the session (restart, expiry). Re-handshake.
            unansweredSince = nil
            output.datagrams += beginHandshake(now: now).datagrams
        }
        return output
    }

    // MARK: Slots

    private enum Slot { case current, previous, next }

    private func keypair(in slot: Slot) -> WireGuardKeypair? {
        switch slot {
        case .current: current
        case .previous: previous
        case .next: next
        }
    }

    private mutating func store(_ keypair: WireGuardKeypair, in slot: Slot) {
        switch slot {
        case .current: current = keypair
        case .previous: previous = keypair
        case .next: next = keypair
        }
    }

    private func freshIndex() -> UInt32 {
        let used = Set(localIndices)
        var index = source.makeIndex()
        while used.contains(index) || index == 0 { index = UInt32.random(in: 1...UInt32.max) }
        return index
    }
}
