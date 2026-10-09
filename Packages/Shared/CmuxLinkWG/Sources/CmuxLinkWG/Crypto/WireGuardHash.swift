/// WireGuard's HASH, MAC, HMAC and KDF over BLAKE2s (whitepaper section 5.4).
struct WireGuardHash {
    let key: [UInt8]

    /// HMAC-BLAKE2s with this key (RFC 2104, block 64).
    func hmac(_ input: [UInt8]) -> [UInt8] {
        var block = key.count > Blake2s.blockLength ? Blake2s.hash(key) : key
        block += [UInt8](repeating: 0, count: Blake2s.blockLength - block.count)
        let inner = Blake2s.hash(block.map { $0 ^ 0x36 }, input)
        return Blake2s.hash(block.map { $0 ^ 0x5C }, inner)
    }

    /// KDF_n(key = chaining key, input): n outputs of 32 bytes.
    func kdf(_ input: [UInt8], outputs: Int) -> [[UInt8]] {
        let secret = WireGuardHash(key: hmac(input))
        var results: [[UInt8]] = []
        var previous: [UInt8] = []
        for index in 1...outputs {
            previous = secret.hmac(previous + [UInt8(index)])
            results.append(previous)
        }
        return results
    }

    static func hash(_ parts: [UInt8]...) -> [UInt8] {
        var hasher = Blake2s()
        for part in parts { hasher.update(part) }
        return hasher.finalize()
    }

    /// MAC(key, input) = keyed BLAKE2s with a 16-byte output.
    static func mac(key: [UInt8], _ input: [UInt8]) throws -> [UInt8] {
        try Blake2s.hash(input, outputLength: 16, key: key)
    }
}
