import CoreGraphics
import Foundation
import Bonsplit
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(Security)
import Security
#endif


// MARK: - Surface resume approval records, canonicalization, and signatures
nonisolated struct SurfaceResumeApprovalRecord: Codable, Equatable, Identifiable, Sendable {
    var version: Int
    var id: String
    var name: String?
    var commandPrefix: [String]
    var cwd: String?
    var environment: [String: String]?
    var environmentKeys: [String]
    var source: String?
    var policy: SurfaceResumeApprovalPolicy
    var createdAt: TimeInterval
    var updatedAt: TimeInterval
    var lastUsedAt: TimeInterval?
    var signature: String?

    init(
        id: String = UUID().uuidString.lowercased(),
        name: String? = nil,
        commandPrefix: [String],
        cwd: String? = nil,
        environment: [String: String]? = nil,
        environmentKeys: [String] = [],
        source: String? = nil,
        policy: SurfaceResumeApprovalPolicy,
        createdAt: TimeInterval = Date().timeIntervalSince1970,
        updatedAt: TimeInterval = Date().timeIntervalSince1970,
        lastUsedAt: TimeInterval? = nil,
        signature: String? = nil
    ) {
        self.version = 1
        self.id = id
        self.name = Self.normalized(name)
        self.commandPrefix = commandPrefix.filter { !$0.isEmpty }
        self.cwd = SurfaceResumeCommandCanonicalizer.normalizedCWD(cwd)
        self.environment = Self.normalizedEnvironment(environment)
        self.environmentKeys = Self.normalizedEnvironmentKeys(environmentKeys, environment: self.environment)
        self.source = Self.normalized(source)
        self.policy = policy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastUsedAt = lastUsedAt
        self.signature = Self.normalized(signature)
    }

    var commandPrefixText: String {
        commandPrefix.map(SurfaceResumeCommandCanonicalizer.shellQuoted).joined(separator: " ")
    }

    func matches(_ binding: SurfaceResumeBindingSnapshot) -> Bool {
        guard !commandPrefix.isEmpty,
              let tokens = SurfaceResumeCommandCanonicalizer.tokens(from: binding.command),
              tokens.count >= commandPrefix.count,
              Array(tokens.prefix(commandPrefix.count)) == commandPrefix else {
            return false
        }
        if let cwd {
            guard SurfaceResumeCommandCanonicalizer.normalizedCWD(binding.cwd) == cwd else {
                return false
            }
        }
        let bindingEnvironment = binding.environment ?? [:]
        guard let environment, !environment.isEmpty else {
            return bindingEnvironment.isEmpty
        }
        return bindingEnvironment == environment
    }

    func signingPayloadData() -> Data {
        let encodedPrefix = commandPrefix
            .map { Data($0.utf8).base64EncodedString() }
            .joined(separator: ",")
        let encodedEnvironmentKeys = environmentKeys
            .map { Data($0.utf8).base64EncodedString() }
            .joined(separator: ",")
        let encodedEnvironment = (environment ?? [:])
            .keys
            .sorted()
            .map { key in
                let value = environment?[key] ?? ""
                return "\(Data(key.utf8).base64EncodedString())=\(Data(value.utf8).base64EncodedString())"
            }
            .joined(separator: ",")
        let fields = [
            "version=\(version)",
            "id=\(id)",
            "name=\(name.map { Data($0.utf8).base64EncodedString() } ?? "")",
            "commandPrefix=\(encodedPrefix)",
            "cwd=\(cwd.map { Data($0.utf8).base64EncodedString() } ?? "")",
            "environment=\(encodedEnvironment)",
            "environmentKeys=\(encodedEnvironmentKeys)",
            "source=\(source.map { Data($0.utf8).base64EncodedString() } ?? "")",
            "policy=\(policy.rawValue)",
            "createdAt=\(createdAt)",
            "updatedAt=\(updatedAt)",
            "lastUsedAt=\(lastUsedAt.map { String($0) } ?? "")",
        ]
        return fields.joined(separator: "\n").data(using: .utf8) ?? Data()
    }

    func signed(secret: Data) -> SurfaceResumeApprovalRecord {
        var copy = self
        copy.signature = SurfaceResumeApprovalSignature.sign(copy.signingPayloadData(), secret: secret)
        return copy
    }

    func hasValidSignature(secret: Data) -> Bool {
        guard let signature else { return false }
        return SurfaceResumeApprovalSignature.sign(signingPayloadData(), secret: secret) == signature
    }

    private static func normalized(_ rawValue: String?) -> String? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }
        return rawValue
    }

    private static func normalizedEnvironment(_ environment: [String: String]?) -> [String: String]? {
        guard let environment else { return nil }
        let normalized = environment.reduce(into: [String: String]()) { result, item in
            let key = item.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return }
            guard isSafeEnvironmentValue(item.value) else { return }
            result[key] = item.value
        }
        return normalized.isEmpty ? nil : normalized
    }

    private static func isSafeEnvironmentValue(_ value: String) -> Bool {
        !value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    private static func normalizedEnvironmentKeys(
        _ environmentKeys: [String],
        environment: [String: String]?
    ) -> [String] {
        let explicitKeys = environmentKeys
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let environmentDerivedKeys: [String] = environment.map { Array($0.keys) } ?? []
        return Array(Set(explicitKeys + environmentDerivedKeys)).sorted()
    }
}

enum SurfaceResumeCommandCanonicalizer {
    static func tokens(from command: String) -> [String]? {
        let scalars = Array(command.unicodeScalars)
        var tokens: [String] = []
        var token = String.UnicodeScalarView()
        var index = 0
        var quote: UnicodeScalar?

        func flushToken() {
            guard !token.isEmpty else { return }
            tokens.append(String(token))
            token.removeAll(keepingCapacity: true)
        }

        while index < scalars.count {
            let scalar = scalars[index]
            if let activeQuote = quote {
                if scalar == activeQuote {
                    quote = nil
                } else if activeQuote == "\"", scalar == "\\", index + 1 < scalars.count {
                    index += 1
                    token.append(scalars[index])
                } else {
                    token.append(scalar)
                }
            } else if scalar == "'" || scalar == "\"" {
                quote = scalar
            } else if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                flushToken()
            } else if scalar == "\\", index + 1 < scalars.count {
                index += 1
                token.append(scalars[index])
            } else {
                token.append(scalar)
            }
            index += 1
        }

        guard quote == nil else { return nil }
        flushToken()
        return tokens.isEmpty ? nil : tokens
    }

    static func normalizedCWD(_ rawValue: String?) -> String? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }
        return ((rawValue as NSString).expandingTildeInPath as NSString).standardizingPath
    }

    static func shellQuoted(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_+-=./:@%")
        if value.unicodeScalars.allSatisfy({ allowed.contains($0) }) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum SurfaceResumeApprovalSignature {
    static func sign(_ payload: Data, secret: Data) -> String {
#if canImport(CryptoKit)
        let key = SymmetricKey(data: secret)
        let code = HMAC<SHA256>.authenticationCode(for: payload, using: key)
        return Data(code).base64EncodedString()
#else
        return ""
#endif
    }
}

