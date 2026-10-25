import CoreGraphics
import Foundation
import Testing
@testable import CmuxVNC

/// A scripted server: hands out its bytes in small chunks (to exercise
/// buffering across reads) and records what the client sent.
final class ScriptedTransport: RFBTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [UInt8]
    private let chunk: Int
    private var sentBytes: [UInt8] = []

    init(_ bytes: [UInt8], chunk: Int = 7) {
        pending = bytes
        self.chunk = chunk
    }

    var sent: [UInt8] { lock.withLock { sentBytes } }

    func open() async throws {}

    func receive() async throws -> [UInt8] {
        try lock.withLock {
            guard !pending.isEmpty else { throw RFBError.connectionClosed }
            let count = min(chunk, pending.count)
            defer { pending.removeFirst(count) }
            return Array(pending[0 ..< count])
        }
    }

    func send(_ bytes: [UInt8]) async throws {
        lock.withLock { sentBytes += bytes }
    }

    func close() {}
}

struct Bytes {
    var data: [UInt8] = []
    mutating func u8(_ v: Int) { data.append(UInt8(v)) }
    mutating func u16(_ v: Int) { data += [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
    mutating func u32(_ v: Int) { data += [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
    mutating func s32(_ v: Int32) { u32(Int(UInt32(bitPattern: v))) }
    mutating func string(_ s: String) { u32(s.utf8.count); data += Array(s.utf8) }
}

func serverInit(width: Int, height: Int, name: String = "test") -> [UInt8] {
    var b = Bytes()
    b.u16(width)
    b.u16(height)
    b.data += RFBPixelFormat.bgrx.encoded
    b.string(name)
    return b.data
}

struct RFBHandshakeTests {
    @Test func noneSecurityOn38() async throws {
        var server = Bytes()
        server.data += Array("RFB 003.008\n".utf8)
        server.u8(1); server.u8(1)          // one type: None
        server.u32(0)                        // SecurityResult OK
        server.data += serverInit(width: 640, height: 480, name: "box")
        let transport = ScriptedTransport(server.data)
        let reader = RFBReader(transport: transport)
        let info = try await RFBHandshake(credentials: VNCCredentials()).run(reader: reader, transport: transport)
        #expect(info.width == 640 && info.height == 480 && info.name == "box" && info.protocolMinor == 8)
        #expect(transport.sent == Array("RFB 003.008\n".utf8) + [1, 1])
    }

    @Test func appleVersionNegotiatesAs38() async throws {
        var server = Bytes()
        server.data += Array("RFB 003.889\n".utf8)
        server.u8(1); server.u8(1)
        server.u32(0)
        server.data += serverInit(width: 10, height: 10)
        let transport = ScriptedTransport(server.data)
        let info = try await RFBHandshake(credentials: VNCCredentials()).run(reader: RFBReader(transport: transport), transport: transport)
        #expect(info.protocolMinor == 8)
    }

    @Test func vncPasswordAuthentication() async throws {
        let challenge = (0 ..< 16).map { UInt8($0 * 7 & 0xFF) }
        var server = Bytes()
        server.data += Array("RFB 003.008\n".utf8)
        server.u8(1); server.u8(2)
        server.data += challenge
        server.u32(0)
        server.data += serverInit(width: 8, height: 8)
        let transport = ScriptedTransport(server.data)
        _ = try await RFBHandshake(credentials: VNCCredentials(password: "secret")).run(reader: RFBReader(transport: transport), transport: transport)
        let expected = VNCPasswordResponse(password: "secret", challenge: challenge).bytes
        #expect(expected.count == 16)
        #expect(Array(transport.sent[12 ..< 13]) == [2])
        #expect(Array(transport.sent[13 ..< 29]) == expected)
    }

    @Test func refusedPasswordReportsReason() async throws {
        var server = Bytes()
        server.data += Array("RFB 003.008\n".utf8)
        server.u8(1); server.u8(2)
        server.data += [UInt8](repeating: 1, count: 16)
        server.u32(1)
        server.string("bad password")
        let transport = ScriptedTransport(server.data)
        await #expect(throws: RFBError.authenticationFailed("bad password")) {
            try await RFBHandshake(credentials: VNCCredentials(password: "x")).run(reader: RFBReader(transport: transport), transport: transport)
        }
    }

    @Test func securityChoice() throws {
        let both = RFBHandshake(credentials: VNCCredentials(username: "u", password: "p"))
        #expect(try both.choose(from: [2, 30]) == 30)
        #expect(try RFBHandshake(credentials: VNCCredentials(password: "p")).choose(from: [2, 30]) == 2)
        #expect(throws: RFBError.credentialsRequired) { try RFBHandshake(credentials: VNCCredentials()).choose(from: [30]) }
        #expect(throws: RFBError.passwordRequired) { try RFBHandshake(credentials: VNCCredentials()).choose(from: [2]) }
        #expect(try RFBHandshake(credentials: VNCCredentials()).choose(from: [2, 1]) == 1)
    }

    @Test func accountPasswordNeverGoesOutAsAVNCPassword() throws {
        let account = RFBHandshake(credentials: VNCCredentials(username: "me", password: "secret"))
        // It asks for a VNC password instead of sending the account password's DES response.
        #expect(throws: RFBError.passwordRequired) { try account.choose(from: [2]) }
        #expect(try account.choose(from: [2, 30]) == 30)
    }

    @Test func oversizedServerInitIsRejected() async {
        var server = Bytes()
        server.data += Array("RFB 003.008\n".utf8)
        server.u8(1); server.u8(1)
        server.u32(0)
        server.data += serverInit(width: 65535, height: 65535)
        let transport = ScriptedTransport(server.data)
        await #expect(throws: RFBError.self) {
            try await RFBHandshake(credentials: VNCCredentials()).run(reader: RFBReader(transport: transport), transport: transport)
        }
    }

    @Test func protocol33TypeComparesTheWholeWord() async {
        var server = Bytes()
        server.data += Array("RFB 003.003\n".utf8)
        server.u32(258)
        let transport = ScriptedTransport(server.data)
        await #expect(throws: RFBError.self) {
            try await RFBHandshake(credentials: VNCCredentials(password: "x")).run(reader: RFBReader(transport: transport), transport: transport)
        }
    }

    @Test func protocol33ServerChoosesType() async throws {
        var server = Bytes()
        server.data += Array("RFB 003.003\n".utf8)
        server.u32(1)
        server.data += serverInit(width: 4, height: 4)
        let transport = ScriptedTransport(server.data)
        let info = try await RFBHandshake(credentials: VNCCredentials()).run(reader: RFBReader(transport: transport), transport: transport)
        #expect(info.protocolMinor == 3)
        #expect(transport.sent == Array("RFB 003.003\n".utf8) + [1])
    }
}

struct VNCEndpointTests {
    @Test(arguments: [
        ("host", "host", 5900),
        ("host:1", "host", 5901),
        ("host:5905", "host", 5905),
        ("host::42", "host", 42),
        ("[::1]:5901", "::1", 5901),
        ("vnc://me:pw@mac.local:5900", "mac.local", 5900),
    ])
    func parses(raw: String, host: String, port: Int) throws {
        let parsed = try #require(VNCEndpoint.parse(raw))
        #expect(parsed.endpoint.host == host)
        #expect(Int(parsed.endpoint.port) == port)
    }

    @Test func credentialsFromURL() throws {
        let parsed = try #require(VNCEndpoint.parse("vnc://me:p%40ss@mac.local"))
        #expect(parsed.credentials == VNCCredentials(username: "me", password: "p@ss"))
    }

    @Test func rejectsEmpty() {
        #expect(VNCEndpoint.parse("") == nil)
        #expect(VNCEndpoint.parse("host:notaport") == nil)
    }
}

struct VNCKeysymTests {
    @Test func hidLetterDigitAndSpecials() {
        #expect(VNCKeysym(hidUsage: 0x07_0004)?.rawValue == 0x61)   // a
        #expect(VNCKeysym(hidUsage: 0x1E)?.rawValue == 0x31)        // 1
        #expect(VNCKeysym(hidUsage: 0x27)?.rawValue == 0x30)        // 0
        #expect(VNCKeysym(hidUsage: 0x28) == .returnKey)
        #expect(VNCKeysym(hidUsage: 0x3A) == .function(1))
        #expect(VNCKeysym(hidUsage: 0x45) == .function(12))
        #expect(VNCKeysym(hidUsage: 0xE3) == .command)
        #expect(VNCKeysym(hidUsage: 0xE2) == .option)
        #expect(VNCKeysym(hidUsage: 0x0C_00E9) == nil)              // consumer page
    }

    @Test func characters() {
        #expect(VNCKeysym(character: "a").rawValue == 0x61)
        #expect(VNCKeysym(character: "é").rawValue == 0xE9)
        #expect(VNCKeysym(character: "€").rawValue == 0x0100_20AC)
        #expect(VNCKeysym(character: "\n") == .returnKey)
    }
}

struct AuthenticationTests {
    @Test func vncDESKnownAnswer() {
        // DES-ECB with key 0e86ceceeef64e26 ("password", each byte's bits
        // reversed), computed independently with `openssl enc -des-ecb`.
        let response = VNCPasswordResponse(password: "password", challenge: Array(0 ..< 16)).bytes
        #expect(response == hex("b866924125c8eebb9debc1db61c538e2"))
    }

    @Test func modularExponentiationSmall() throws {
        let math = try #require(ModularExponentiation(modulus: [23]))
        #expect(math.power([5], [6]) == [8])
        #expect(math.power([8], [6]) == [13])
        #expect(ModularExponentiation(modulus: [24]) == nil)
    }

    @Test func modularExponentiationMatchesReference() throws {
        // 1024-bit Oakley group 2 prime (RFC 2409), g = 2.
        let math = try #require(ModularExponentiation(modulus: hex(oakley2)))
        #expect(math.power([0, 2], hex(exponent)) == hex(expected))
    }

    @Test func appleDHRoundTrip() throws {
        let auth = AppleDHAuthentication(generator: 5, prime: [23], serverPublicKey: [8])
        let padding = (0 ..< 128).map { UInt8($0) }
        let response = try #require(auth.response(username: "bob", password: "pw", privateKey: [6], padding: padding))
        #expect(response.clientPublicKey == [8])
        #expect(response.encryptedCredentials.count == 128)
        let credentials = AppleDHAuthentication.credentials(username: "bob", password: "pw", padding: padding)
        #expect(Array(credentials[0 ..< 4]) == Array("bob".utf8) + [0])
        #expect(Array(credentials[64 ..< 67]) == Array("pw".utf8) + [0])
    }
}

func hex(_ text: String) -> [UInt8] {
    let digits = Array(text.filter(\.isHexDigit))
    return stride(from: 0, to: digits.count, by: 2).map { UInt8(String(digits[$0 ..< $0 + 2]), radix: 16)! }
}

let oakley2 = "ffffffffffffffffc90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74020bbea63b139b22514a08798e3404ddef9519b3cd3a431b302b0a6df25f14374fe1356d6d51c245e485b576625e7ec6f44c42e9a637ed6b0bff5cb6f406b7edee386bfb5a899fa5ae9f24117c4b1fe649286651ece65381ffffffffffffffff"
let exponent = "1f2e3d4c5b6a79881726354453627180ffeeddccbbaa99887766554433221100a5a5a5a51f2e3d4c5b6a79881726354453627180ffeeddccbbaa99887766554433221100a5a5a5a51f2e3d4c5b6a79881726354453627180ffeeddccbbaa99887766554433221100a5a5a5a5"
/// `pow(2, exponent, oakley2)` from Python.
let expected = "a6ca431cee9c05952f52ec33d2995c5c4ef65a69a923f7bb294289dde8921168849b87b571588918c812fc721e3b0e164d36261679fd74d07ac4f71d3f493bda6a12d7072ae9b1b5f5f1d31bc3cb25611c7ac7080c0ca372638381285fd59e910dfcf010a1b7c0b9414def2b6aa2e0adf05cbe0026f8f79012a7d89eda469255"
