@testable import CmuxLinkWG
import Testing

/// BLAKE2s and the WireGuard hash functions against RFC 7693 and Python's
/// `hashlib.blake2s` / `hmac` (an independent implementation).
@Suite("Crypto")
struct CryptoTests {
    private let message = [UInt8](0..<200)
    private let key = [UInt8](0..<32)

    @Test func blake2sUnkeyed() {
        #expect(Blake2s.hash([]).hex == "69217a3079908094e11121d042354a7c1f55b6482ca1a51e1b250dfd1ed0eef9")
        #expect(Blake2s.hash(Array("abc".utf8)).hex == "508c5e8c327c14e2e1a72ba34eeb452f37458b209ed63a294d999b4c86675982")
        #expect(Blake2s.hash([UInt8](repeating: 0, count: 64)).hex == "ae09db7cd54f42b490ef09b6bc541af688e4959bb8c53f359a6f56e38ab454a3")
        #expect(Blake2s.hash(message).hex == "6d244e1a06ce4ef578dd0f63aff0936706735119ca9c8d22d86c801414ab9741")
    }

    @Test func blake2sIncrementalMatchesOneShot() {
        var hasher = Blake2s()
        hasher.update(message[..<63])
        hasher.update(message[63..<64])
        hasher.update(message[64...])
        #expect(hasher.finalize() == Blake2s.hash(message))
    }

    @Test func blake2sKeyed() {
        #expect(Blake2s.hash(message, key: key).hex == "13c88480a5d00d6c8c7ad2110d76a82d9b70f4fa6696d4e5dd42a066dcaf9920")
        #expect(Blake2s.hash([], key: key).hex == "48a8997da407876b3d79c0d92325ad3b89cbb754d86ab71aee047ad345fd2c49")
        #expect(WireGuardHash.mac(key: Array(key[..<16]), message).hex == "b8d300fa7937e4d1e67c8468df4c9a43")
    }

    @Test func hmacBlake2s() {
        #expect(WireGuardHash(key: key).hmac(message).hex == "543eec9b22646365ef782d72dae137cc761d018005f8d33d0f20bfbd01e62974")
        #expect(WireGuardHash(key: [UInt8](0..<65)).hmac(Array("abc".utf8)).hex == "44d87b3939dec16bc76cbd83e3982ac0a4eafab8a5b87c8c2adbd0da7d5c9695")
    }

    @Test func protocolConstants() {
        #expect(WireGuardProtocol.initialChainKey.hex == "60e26daef327efc02ec335e2a025d2d016eb4206f87277f52d38d1988b78cd36")
        #expect(WireGuardProtocol.initialHash.hex == "2211b361081ac566691243db458ad5322d9c6c662293e8b70ee19c65ba079ef3")
    }

    @Test func kdfChainsHMAC() {
        let outputs = WireGuardHash(key: key).kdf(message, outputs: 3)
        let secret = WireGuardHash(key: WireGuardHash(key: key).hmac(message))
        let first = secret.hmac([1])
        let second = secret.hmac(first + [2])
        #expect(outputs == [first, second, secret.hmac(second + [3])])
    }

    @Test func replayWindow() {
        var window = ReplayWindow()
        var results: [Bool] = []
        for counter: UInt64 in [0, 0, 5, 3, 3, 2052] { results.append(window.accept(counter)) }
        #expect(results == [true, false, true, true, false, true])
        #expect(!window.canAccept(4), "counter 4 is 2048 behind the greatest")
        #expect(window.canAccept(5000))
        let jumped = window.accept(1_000_000)
        #expect(jumped)
        #expect(!window.canAccept(5000))
    }
}
