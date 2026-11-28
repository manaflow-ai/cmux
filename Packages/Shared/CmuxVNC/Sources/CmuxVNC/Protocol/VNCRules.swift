import Foundation

/// The RFB client's rules, asked of Rust (cmux-tui/crates/cmux-vnc, with their tests; ops
/// `vnc_*`): the version banner, the security choice, VNC password and Apple DH
/// authentication. This package links no Rust library itself, so the process that makes a client
/// hands it a channel (``VNCSessionOptions/rules``): the Mac app's is cmux-layout-reducer-ffi's
/// `cmux_layout_reducer_json`, the phone's cmux-mobile-link-ffi's `vnc_json`. Without one a
/// client fails the handshake with ``VNCRules/unavailable``.
public struct VNCRules: Sendable {
    /// One JSON call: the operation and its request, the answer (nil: no answer).
    public typealias Ask = @Sendable (_ operation: String, _ request: Data) -> Data?

    private let channel: Ask?

    /// The rules answered by `ask`; none without it.
    public init(_ ask: Ask? = nil) {
        channel = ask
    }

    /// What a handshake without rules fails with (a build that did not hand its client a channel).
    public static let unavailable = RFBError.transport("no VNC rules channel (cmux-vnc)")

    /// Whether there is a channel.
    public var installed: Bool { channel != nil }

    /// One call, decoded; nil without a channel or for an answer that does not decode (JSON
    /// `null` decodes to nil for an optional `Answer`). Public for the other modules that ask
    /// `vnc_*` ops (CmuxVNCDemoServer's `vnc_demo_*`).
    public func ask<Answer: Decodable>(_ operation: String, _ request: some Encodable, as _: Answer.Type = Answer.self) -> Answer? {
        guard let channel, let data = try? JSONEncoder().encode(request),
              let answer = channel(operation, data) else { return nil }
        return try? JSONDecoder().decode(Answer.self, from: answer)
    }

    /// The 16-byte VNC authentication response to `challenge` (DES keyed by the password).
    public func passwordResponse(password: String, challenge: [UInt8]) -> [UInt8]? {
        struct Request: Encodable { var password: String, challenge: Data }
        struct Answer: Decodable { var response: Data }
        return ask("vnc_password_response", Request(password: password, challenge: Data(challenge)), as: Answer.self)
            .map { Array($0.response) }
    }

    /// The server's minor version from its 12-byte banner, the minor this client speaks and the
    /// banner to answer with; nil for a banner that is not RFB 3.x (or without rules).
    func version(banner: [UInt8]) -> (server: Int, minor: Int, reply: [UInt8])? {
        struct Request: Encodable { var banner: Data }
        struct Answer: Decodable { var serverMinor: Int, minor: Int, reply: Data }
        guard let answer = ask("vnc_version", Request(banner: Data(banner)), as: Answer?.self) ?? nil else { return nil }
        return (answer.serverMinor, answer.minor, Array(answer.reply))
    }

    private struct Choice: Decodable {
        var type: UInt8?
        var refusal: String?
        var offered: [UInt8]?

        func result() throws -> UInt8 {
            if let type { return type }
            switch refusal {
            case "credentialsRequired": throw RFBError.credentialsRequired
            case "passwordRequired": throw RFBError.passwordRequired
            case "noSupportedSecurityType": throw RFBError.noSupportedSecurityType(offered ?? [])
            default: throw VNCRules.unavailable
            }
        }
    }

    /// RFB 3.7+: the type to answer from the server's list (Apple DH with a user name, the VNC
    /// password without one, then none), or the refusal.
    func chooseSecurity(offered: [UInt8], credentials: VNCCredentials) throws -> UInt8 {
        struct Request: Encodable { var offered: [UInt8], hasUsername: Bool, hasPassword: Bool }
        let request = Request(offered: offered, hasUsername: credentials.username != nil, hasPassword: credentials.password != nil)
        guard let choice = ask("vnc_security_choose", request, as: Choice.self) else { throw Self.unavailable }
        return try choice.result()
    }

    /// RFB 3.3: the type the server chose (its 32-bit word, not 0), or the refusal.
    func serverChosenSecurity(word: UInt32, credentials: VNCCredentials) throws -> UInt8 {
        struct Request: Encodable { var word: UInt32, hasUsername: Bool }
        let request = Request(word: word, hasUsername: credentials.username != nil)
        guard let choice = ask("vnc_security_server_chosen", request, as: Choice.self) else { throw Self.unavailable }
        return try choice.result()
    }

    /// Apple DH (type 30): the encrypted 128-byte credential block and this side's public key,
    /// sent in that order; nil for a bad key. `privateKey` and `padding` fix the result in tests.
    func appleDH(generator: UInt16, prime: [UInt8], serverPublicKey: [UInt8], username: String, password: String,
                 privateKey: [UInt8]? = nil, padding: [UInt8]? = nil) -> [UInt8]? {
        struct Request: Encodable {
            var generator: UInt16, prime: Data, serverPublicKey: Data, username: String, password: String
            var privateKey: Data?, padding: Data?
        }
        struct Answer: Decodable { var encryptedCredentials: Data, clientPublicKey: Data }
        let request = Request(generator: generator, prime: Data(prime), serverPublicKey: Data(serverPublicKey),
                              username: username, password: password,
                              privateKey: privateKey.map { Data($0) }, padding: padding.map { Data($0) })
        guard let answer = ask("vnc_apple_dh", request, as: Answer?.self) ?? nil else { return nil }
        return Array(answer.encryptedCredentials) + Array(answer.clientPublicKey)
    }
}
