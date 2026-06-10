import Foundation
import CMUXAgentLaunch
import CmuxFoundation
import CmuxSocketControl
import CoreFoundation
import CryptoKit
import Darwin
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif
#if canImport(Sentry)
import Sentry
#endif


// MARK: - VM create idempotency
extension CMUXCLI {
    private static let vmCreateIdempotencyTTLSeconds: TimeInterval = 10 * 60
    static let vmCreateResponseTimeoutSeconds: TimeInterval = 16 * 60
    static let vmAttachResponseTimeoutSeconds: TimeInterval = 16 * 60
    private struct VMCreateIdempotencyStore: Codable {
        var records: [String: VMCreateIdempotencyRecord] = [:]
    }

    private struct VMCreateIdempotencyRecord: Codable {
        let key: String
        let createdAt: TimeInterval
    }

    struct ActiveVMCreateIdempotency {
        let signature: String
        let key: String
    }

    static func normalizedEnvValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    static func isCodingAgentEnvironment(_ environment: [String: String]) -> Bool {
        if let kind = normalizedEnvValue(environment["CMUX_AGENT_LAUNCH_KIND"])?.lowercased() {
            let agentKinds: Set<String> = [
                "claude",
                "codex",
                "opencode",
                "omo",
                "omx",
                "omc",
            ]
            if agentKinds.contains(kind) {
                return true
            }
        }

        let directAgentKeys = [
            "CODEX_CI",
            "CODEX_THREAD_ID",
            "CODEX_SESSION_ID",
            "CODEX_SANDBOX",
            "CODEX_MANAGED_BY_BUN",
            "CLAUDECODE",
            "CLAUDE_CODE",
            "CLAUDE_CODE_ENTRYPOINT",
            "CLAUDE_CODE_SESSION_ID",
            "OPENCODE",
            "OPENCODE_PORT",
            "OPENCODE_SESSION_ID",
        ]
        return directAgentKeys.contains { normalizedEnvValue(environment[$0]) != nil }
    }

    private static func vmCreateIdempotencySignature(image: String?, provider: String?) -> String {
        let normalizedImage = image?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedProvider = provider?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        return "image=\(normalizedImage)\u{1f}provider=\(normalizedProvider)"
    }

    static func normalizedVMProvider(_ provider: String?) throws -> String? {
        guard let trimmed = provider?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        let normalized = trimmed.lowercased()
        guard normalized == "e2b" || normalized == "freestyle" else {
            throw CLIError(message: """
                vm new: unsupported Cloud VM service override.

                Try:
                  cmux vm new
                """)
        }
        return normalized
    }

    static func isFlagToken(_ value: String) -> Bool { value.hasPrefix("-") && value != "-" }

    static func isUnknownFlagToken(_ value: String, allowedShortFlags: Set<String> = []) -> Bool { isFlagToken(value) && !allowedShortFlags.contains(value) }

    private static func vmCreateIdempotencyStoreURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cmuxterm", isDirectory: true)
            .appendingPathComponent("vm-create-idempotency.json", isDirectory: false)
    }

    private static func loadVMCreateIdempotencyStore(from url: URL) -> VMCreateIdempotencyStore {
        guard let data = try? Data(contentsOf: url),
              let store = try? JSONDecoder().decode(VMCreateIdempotencyStore.self, from: data) else {
            return VMCreateIdempotencyStore()
        }
        return store
    }

    private static func saveVMCreateIdempotencyStore(_ store: VMCreateIdempotencyStore, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(store)
        try data.write(to: url, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func activeVMCreateIdempotency(image: String?, provider: String?) throws -> ActiveVMCreateIdempotency {
        let url = vmCreateIdempotencyStoreURL()
        let signature = vmCreateIdempotencySignature(image: image, provider: provider)
        let now = Date().timeIntervalSince1970
        var store = loadVMCreateIdempotencyStore(from: url)
        store.records = store.records.filter { _, record in
            !record.key.isEmpty && now - record.createdAt < vmCreateIdempotencyTTLSeconds
        }
        if let existing = store.records[signature] {
            try saveVMCreateIdempotencyStore(store, to: url)
            return ActiveVMCreateIdempotency(signature: signature, key: existing.key)
        }
        let key = UUID().uuidString.lowercased()
        store.records[signature] = VMCreateIdempotencyRecord(key: key, createdAt: now)
        try saveVMCreateIdempotencyStore(store, to: url)
        return ActiveVMCreateIdempotency(signature: signature, key: key)
    }

    static func clearVMCreateIdempotency(_ active: ActiveVMCreateIdempotency) {
        let url = vmCreateIdempotencyStoreURL()
        var store = loadVMCreateIdempotencyStore(from: url)
        guard store.records[active.signature]?.key == active.key else { return }
        store.records.removeValue(forKey: active.signature)
        try? saveVMCreateIdempotencyStore(store, to: url)
    }

}
