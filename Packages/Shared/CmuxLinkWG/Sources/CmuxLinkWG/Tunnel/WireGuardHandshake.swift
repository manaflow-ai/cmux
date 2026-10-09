/// The two handshake messages of WireGuard (whitepaper section 5.4.2 and
/// 5.4.3). Pure functions of keys and inputs; the tunnel owns the state.
struct WireGuardHandshake {
    let identity: WireGuardPrivateKey
    let localPublic: [UInt8]

    init(identity: WireGuardPrivateKey) {
        self.identity = identity
        localPublic = identity.publicKey.bytes
    }

    // MARK: Initiator

    func makeInitiation(
        to peer: [UInt8],
        localIndex: UInt32,
        ephemeral: WireGuardPrivateKey,
        timestamp: TAI64N,
        now: Duration
    ) throws -> WireGuardInitiation {
        var chain = WireGuardProtocol.initialChainKey
        var hash = WireGuardHash.hash(WireGuardProtocol.initialHash, peer)
        let ephemeralPublic = ephemeral.publicKey.bytes
        chain = WireGuardHash(key: chain).kdf(ephemeralPublic, outputs: 1)[0]
        hash = WireGuardHash.hash(hash, ephemeralPublic)
        var keys = WireGuardHash(key: chain).kdf(try ephemeral.sharedSecret(with: peer), outputs: 2)
        chain = keys[0]
        let encryptedStatic = try WireGuardAEAD(key: keys[1]).seal(localPublic, counter: 0, authenticating: hash)
        hash = WireGuardHash.hash(hash, encryptedStatic)
        keys = WireGuardHash(key: chain).kdf(try identity.sharedSecret(with: peer), outputs: 2)
        chain = keys[0]
        let encryptedTimestamp = try WireGuardAEAD(key: keys[1]).seal(timestamp.bytes, counter: 0, authenticating: hash)
        hash = WireGuardHash.hash(hash, encryptedTimestamp)

        var message = [WireGuardProtocol.initiationType, 0, 0, 0] + WireGuardProtocol.le32(localIndex)
        message += ephemeralPublic + encryptedStatic + encryptedTimestamp
        message += WireGuardHash.mac(key: WireGuardProtocol.mac1Key(for: peer), message)
        message += [UInt8](repeating: 0, count: 16)
        return WireGuardInitiation(
            localIndex: localIndex, chainKey: chain, hash: hash, ephemeral: ephemeral, sentAt: now, message: message
        )
    }

    func consumeResponse(_ message: [UInt8], to initiation: WireGuardInitiation, peer: [UInt8], now: Duration) throws -> WireGuardKeypair {
        guard message.count == WireGuardProtocol.responseLength else { throw WireGuardTunnelError.malformedMessage }
        try verifyMAC1(message)
        let remoteIndex = WireGuardProtocol.readLE32(message, at: 4)
        guard WireGuardProtocol.readLE32(message, at: 8) == initiation.localIndex else { throw WireGuardTunnelError.unknownIndex }
        let remoteEphemeral = Array(message[12..<44])
        let encryptedNothing = Array(message[44..<60])

        var chain = initiation.chainKey
        var hash = initiation.hash
        chain = WireGuardHash(key: chain).kdf(remoteEphemeral, outputs: 1)[0]
        hash = WireGuardHash.hash(hash, remoteEphemeral)
        chain = WireGuardHash(key: chain).kdf(try initiation.ephemeral.sharedSecret(with: remoteEphemeral), outputs: 1)[0]
        chain = WireGuardHash(key: chain).kdf(try identity.sharedSecret(with: remoteEphemeral), outputs: 1)[0]
        let keys = WireGuardHash(key: chain).kdf(WireGuardProtocol.presharedKey, outputs: 3)
        chain = keys[0]
        hash = WireGuardHash.hash(hash, keys[1])
        _ = try WireGuardAEAD(key: keys[2]).open(encryptedNothing, counter: 0, authenticating: hash)
        let transport = WireGuardHash(key: chain).kdf([], outputs: 2)
        return WireGuardKeypair(
            localIndex: initiation.localIndex,
            remoteIndex: remoteIndex,
            sendKey: WireGuardAEAD(key: transport[0]),
            receiveKey: WireGuardAEAD(key: transport[1]),
            isInitiator: true,
            createdAt: now
        )
    }

    // MARK: Responder

    func consumeInitiation(_ message: [UInt8]) throws -> WireGuardReceivedInitiation {
        guard message.count == WireGuardProtocol.initiationLength else { throw WireGuardTunnelError.malformedMessage }
        try verifyMAC1(message)
        let remoteIndex = WireGuardProtocol.readLE32(message, at: 4)
        let remoteEphemeral = Array(message[8..<40])
        let encryptedStatic = Array(message[40..<88])
        let encryptedTimestamp = Array(message[88..<116])

        var chain = WireGuardProtocol.initialChainKey
        var hash = WireGuardHash.hash(WireGuardProtocol.initialHash, localPublic)
        chain = WireGuardHash(key: chain).kdf(remoteEphemeral, outputs: 1)[0]
        hash = WireGuardHash.hash(hash, remoteEphemeral)
        var keys = WireGuardHash(key: chain).kdf(try identity.sharedSecret(with: remoteEphemeral), outputs: 2)
        chain = keys[0]
        let peerStatic = try WireGuardAEAD(key: keys[1]).open(encryptedStatic, counter: 0, authenticating: hash)
        hash = WireGuardHash.hash(hash, encryptedStatic)
        keys = WireGuardHash(key: chain).kdf(try identity.sharedSecret(with: peerStatic), outputs: 2)
        chain = keys[0]
        let timestampBytes = try WireGuardAEAD(key: keys[1]).open(encryptedTimestamp, counter: 0, authenticating: hash)
        hash = WireGuardHash.hash(hash, encryptedTimestamp)
        guard let peer = WireGuardPublicKey(rawRepresentation: .init(peerStatic)),
              let timestamp = TAI64N(bytes: timestampBytes)
        else { throw WireGuardTunnelError.malformedMessage }
        return WireGuardReceivedInitiation(
            peer: peer, remoteIndex: remoteIndex, remoteEphemeral: remoteEphemeral,
            chainKey: chain, hash: hash, timestamp: timestamp
        )
    }

    func makeResponse(
        to initiation: WireGuardReceivedInitiation,
        localIndex: UInt32,
        ephemeral: WireGuardPrivateKey,
        now: Duration
    ) throws -> (message: [UInt8], keypair: WireGuardKeypair) {
        var chain = initiation.chainKey
        var hash = initiation.hash
        let ephemeralPublic = ephemeral.publicKey.bytes
        chain = WireGuardHash(key: chain).kdf(ephemeralPublic, outputs: 1)[0]
        hash = WireGuardHash.hash(hash, ephemeralPublic)
        chain = WireGuardHash(key: chain).kdf(try ephemeral.sharedSecret(with: initiation.remoteEphemeral), outputs: 1)[0]
        chain = WireGuardHash(key: chain).kdf(try ephemeral.sharedSecret(with: initiation.peer.bytes), outputs: 1)[0]
        let keys = WireGuardHash(key: chain).kdf(WireGuardProtocol.presharedKey, outputs: 3)
        chain = keys[0]
        hash = WireGuardHash.hash(hash, keys[1])
        let encryptedNothing = try WireGuardAEAD(key: keys[2]).seal([UInt8](), counter: 0, authenticating: hash)

        var message = [WireGuardProtocol.responseType, 0, 0, 0] + WireGuardProtocol.le32(localIndex)
        message += WireGuardProtocol.le32(initiation.remoteIndex) + ephemeralPublic + encryptedNothing
        message += WireGuardHash.mac(key: WireGuardProtocol.mac1Key(for: initiation.peer.bytes), message)
        message += [UInt8](repeating: 0, count: 16)
        let transport = WireGuardHash(key: chain).kdf([], outputs: 2)
        let keypair = WireGuardKeypair(
            localIndex: localIndex,
            remoteIndex: initiation.remoteIndex,
            sendKey: WireGuardAEAD(key: transport[1]),
            receiveKey: WireGuardAEAD(key: transport[0]),
            isInitiator: false,
            createdAt: now
        )
        return (message, keypair)
    }

    /// mac1 covers every byte before it and is keyed by this end's public key.
    private func verifyMAC1(_ message: [UInt8]) throws {
        let macStart = message.count - 32
        let expected = WireGuardHash.mac(key: WireGuardProtocol.mac1Key(for: localPublic), Array(message[..<macStart]))
        guard WireGuardProtocol.equal(message[macStart..<(macStart + 16)], expected) else { throw WireGuardTunnelError.badMAC }
    }
}
