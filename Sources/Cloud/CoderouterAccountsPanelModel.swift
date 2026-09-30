import CmuxCloud
import CmuxControlSocket
import Foundation
import Observation

/// Owns the team-scoped CodeRouter account and usage snapshot shown in the Cloud sidebar.
@MainActor
@Observable
final class CoderouterAccountsPanelModel {
    enum LoadState: Equatable {
        case noTeam
        case loading
        case loaded
        case failed
    }

    enum FailedSource: Hashable {
        case claude
        case native
        case shared
        case usage
    }

    struct ClaudeAccount: Identifiable, Equatable {
        let id: String
        let kind: String
        let label: String
        let identifier: String
        let region: String?
        let state: String
        let cooldownUntil: Date?
        let lastFailureCode: String?
        let lastUsedAt: Date?
    }

    struct SharedAccount: Identifiable, Equatable {
        let id: String
        let kind: String
        let label: String
        let createdAt: Date?
        let healthOK: Bool?
        let healthMessage: String?
    }

    struct NativeAccount: Identifiable, Equatable {
        let id: String
        let provider: String
        let providerAccountID: String
        let label: String
        let state: String
        let cooldownUntil: Date?
        let lastFailureCode: String?
        let activeSessions: Int
    }

    struct UsageSummary: Equatable {
        let totalTokens: Int
        let totalValue: Double
        let maximumTokens: Int
    }

    enum Account: Identifiable, Equatable {
        case claude(ClaudeAccount)
        case native(NativeAccount)
        case shared(SharedAccount)

        var id: String {
            switch self {
            case .claude(let account): return "claude:\(account.id)"
            case .native(let account): return "native:\(account.id)"
            case .shared(let account): return "shared:\(account.id)"
            }
        }

        var rawID: String {
            switch self {
            case .claude(let account): return account.id
            case .native(let account): return account.id
            case .shared(let account): return account.id
            }
        }
    }

    struct Operations {
        typealias ClaudeList = @Sendable (String) async throws -> JSONValue
        typealias NativeList = @Sendable (String) async throws -> JSONValue
        typealias SharedList = @Sendable (String) async throws -> [JSONValue]
        typealias ClaudeAdd = @Sendable (ClaudeUpstreamInput, String?, String) async throws -> JSONValue
        typealias SharedAdd = @Sendable (AIAccountUploadPayload, String) async throws -> JSONValue
        typealias Remove = @Sendable (String, String) async throws -> JSONValue
        typealias ClaudeUpdate = @Sendable (String, String, String) async throws -> JSONValue
        typealias NativeAdd = @Sendable (CoderouterAPIKeyProvider, String, String?, String) async throws -> JSONValue
        typealias Usage = @Sendable (String) async throws -> TeamMachineUsage

        let listClaude: ClaudeList
        let listNative: NativeList
        let listShared: SharedList
        let addClaude: ClaudeAdd
        let addShared: SharedAdd
        let removeClaude: Remove
        let removeShared: Remove
        let updateClaude: ClaudeUpdate
        let addNative: NativeAdd
        let removeNative: Remove
        let loadUsage: Usage

        init(
            listClaude: @escaping ClaudeList,
            listNative: @escaping NativeList,
            listShared: @escaping SharedList,
            addClaude: @escaping ClaudeAdd,
            addShared: @escaping SharedAdd,
            removeClaude: @escaping Remove,
            removeShared: @escaping Remove,
            updateClaude: @escaping ClaudeUpdate,
            addNative: @escaping NativeAdd,
            removeNative: @escaping Remove,
            loadUsage: @escaping Usage
        ) {
            self.listClaude = listClaude
            self.listNative = listNative
            self.listShared = listShared
            self.addClaude = addClaude
            self.addShared = addShared
            self.removeClaude = removeClaude
            self.removeShared = removeShared
            self.updateClaude = updateClaude
            self.addNative = addNative
            self.removeNative = removeNative
            self.loadUsage = loadUsage
        }

        init() {
            let coderouter = CoderouterClient.shared
            let aiAccounts = AIAccountsClient.shared
            let usageClient = MachineUsageClient.shared
            self.init(
                listClaude: { teamID in
                    guard let coderouter else { throw ServiceUnavailable() }
                    return try await coderouter.claudeAccounts(teamID: teamID)
                },
                listNative: { teamID in
                    guard let coderouter else { throw ServiceUnavailable() }
                    return try await coderouter.nativeAccounts(teamID: teamID)
                },
                listShared: { teamID in
                    guard let aiAccounts else { throw ServiceUnavailable() }
                    return try await aiAccounts.list(teamID: teamID)
                },
                addClaude: { input, label, teamID in
                    guard let coderouter else { throw ServiceUnavailable() }
                    return try await coderouter.addClaudeAccount(input, label: label, teamID: teamID)
                },
                addShared: { payload, teamID in
                    guard let aiAccounts else { throw ServiceUnavailable() }
                    return try await aiAccounts.upload(payload, teamID: teamID, validate: true)
                },
                removeClaude: { accountID, teamID in
                    guard let coderouter else { throw ServiceUnavailable() }
                    return try await coderouter.removeClaudeAccount(id: accountID, teamID: teamID)
                },
                removeShared: { accountID, teamID in
                    guard let aiAccounts else { throw ServiceUnavailable() }
                    return try await aiAccounts.remove(id: accountID, teamID: teamID)
                },
                updateClaude: { accountID, state, teamID in
                    guard let coderouter else { throw ServiceUnavailable() }
                    return try await coderouter.updateClaudeAccount(id: accountID, label: nil, state: state, teamID: teamID)
                },
                addNative: { provider, apiKey, label, teamID in
                    guard let coderouter else { throw ServiceUnavailable() }
                    return try await coderouter.addNativeAPIKey(provider: provider, apiKey: apiKey, label: label, teamID: teamID)
                },
                removeNative: { accountID, teamID in
                    guard let coderouter else { throw ServiceUnavailable() }
                    return try await coderouter.removeNativeAccount(id: accountID, teamID: teamID)
                },
                loadUsage: { teamID in
                    guard let usageClient else { throw ServiceUnavailable() }
                    return try await usageClient.teamUsage(teamID: teamID)
                }
            )
        }
    }

    struct ServiceUnavailable: Error, LocalizedError, Sendable {
        var errorDescription: String? {
            String(localized: "coderouter.sidebar.serviceUnavailable", defaultValue: "CodeRouter is temporarily unavailable.")
        }
    }

    private struct DecodeFailure: Error, LocalizedError {
        let field: String

        var errorDescription: String? {
            String(
                format: String(localized: "coderouter.sidebar.invalidResponse", defaultValue: "CodeRouter returned an invalid response (%@)."),
                field
            )
        }
    }

    private let operations: Operations
    private var loadTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private struct Scope: Equatable {
        let teamID: String
        let generation: UInt64
    }
    private static let fractionalISO8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let ISO8601Formatter = ISO8601DateFormatter()

    private(set) var teamID: String?
    private(set) var state: LoadState = .noTeam
    private(set) var accounts: [Account] = []
    private(set) var usage: TeamMachineUsage?
    private(set) var usageSummary: UsageSummary?
    private(set) var failedSources: Set<FailedSource> = []
    private(set) var isMutating = false

    init(operations: Operations = Operations()) {
        self.operations = operations
    }

    deinit {
        loadTask?.cancel()
    }

    var claudeAccounts: [ClaudeAccount] {
        accounts.compactMap { account in
            guard case .claude(let value) = account else { return nil }
            return value
        }
    }

    var sharedAccounts: [SharedAccount] {
        accounts.compactMap { account in
            guard case .shared(let value) = account else { return nil }
            return value
        }
    }

    var nativeAccounts: [NativeAccount] {
        accounts.compactMap { account in
            guard case .native(let value) = account else { return nil }
            return value
        }
    }

    func load(teamID: String?) {
        loadTask?.cancel()
        generation &+= 1
        let normalized = Self.normalizedTeamID(teamID)
        reset(for: normalized)
        guard let normalized else {
            return
        }
        let requestGeneration = generation
        loadTask = Task { @MainActor [weak self] in
            await self?.fetch(teamID: normalized, generation: requestGeneration)
        }
    }

    /// Performs a team read synchronously for callers that need authoritative state after a mutation.
    func reloadNow(teamID: String?) async {
        loadTask?.cancel()
        generation &+= 1
        let normalized = Self.normalizedTeamID(teamID)
        reset(for: normalized)
        guard let normalized else { return }
        await fetch(teamID: normalized, generation: generation)
    }

    func refresh() {
        load(teamID: teamID)
    }

    func cancel() {
        loadTask?.cancel()
        loadTask = nil
    }

    func addClaude(_ input: ClaudeUpstreamInput, label: String?) async throws {
        guard let scope = currentScope() else { throw ServiceUnavailable() }
        isMutating = true
        defer { isMutating = false }
        _ = try await operations.addClaude(input, label, scope.teamID)
        guard currentScope() == scope else { return }
        await reloadNow(teamID: scope.teamID)
    }

    func addShared(_ payload: AIAccountUploadPayload) async throws {
        guard let scope = currentScope() else { throw ServiceUnavailable() }
        isMutating = true
        defer { isMutating = false }
        _ = try await operations.addShared(payload, scope.teamID)
        guard currentScope() == scope else { return }
        await reloadNow(teamID: scope.teamID)
    }

    func addNativeAPIKey(provider: CoderouterAPIKeyProvider, apiKey: String, label: String?) async throws {
        guard let scope = currentScope() else { throw ServiceUnavailable() }
        isMutating = true
        defer { isMutating = false }
        _ = try await operations.addNative(provider, apiKey, label, scope.teamID)
        guard currentScope() == scope else { return }
        await reloadNow(teamID: scope.teamID)
    }

    func remove(_ account: Account) async throws {
        guard let scope = currentScope() else { throw ServiceUnavailable() }
        isMutating = true
        defer { isMutating = false }
        switch account {
        case .claude(let value):
            _ = try await operations.removeClaude(value.id, scope.teamID)
        case .native(let value):
            _ = try await operations.removeNative(value.id, scope.teamID)
        case .shared(let value):
            _ = try await operations.removeShared(value.id, scope.teamID)
        }
        guard currentScope() == scope else { return }
        await reloadNow(teamID: scope.teamID)
    }

    func setClaude(_ account: ClaudeAccount, enabled: Bool) async throws {
        guard let scope = currentScope() else { throw ServiceUnavailable() }
        isMutating = true
        defer { isMutating = false }
        _ = try await operations.updateClaude(account.id, enabled ? "active" : "disabled", scope.teamID)
        guard currentScope() == scope else { return }
        await reloadNow(teamID: scope.teamID)
    }

    private func currentScope() -> Scope? {
        guard let teamID else { return nil }
        return Scope(teamID: teamID, generation: generation)
    }

    private func reset(for teamID: String?) {
        self.teamID = teamID
        accounts = []
        usage = nil
        usageSummary = nil
        failedSources = []
        state = teamID == nil ? .noTeam : .loading
    }

    private func fetch(teamID: String, generation: UInt64) async {
        var fetchedClaude: [ClaudeAccount] = []
        var fetchedNative: [NativeAccount] = []
        var fetchedShared: [SharedAccount] = []
        var fetchedUsage: TeamMachineUsage?
        var failures = Set<FailedSource>()

        do {
            fetchedClaude = try Self.decodeClaudeAccounts(try await operations.listClaude(teamID))
        } catch {
            failures.insert(.claude)
        }
        guard !Task.isCancelled else { return }
        do {
            fetchedNative = try Self.decodeNativeAccounts(try await operations.listNative(teamID))
        } catch {
            failures.insert(.native)
        }
        guard !Task.isCancelled else { return }
        do {
            fetchedShared = try Self.decodeSharedAccounts(try await operations.listShared(teamID))
        } catch {
            failures.insert(.shared)
        }
        guard !Task.isCancelled else { return }
        do {
            fetchedUsage = try await operations.loadUsage(teamID)
        } catch {
            failures.insert(.usage)
        }
        guard !Task.isCancelled, self.generation == generation, self.teamID == teamID else { return }
        accounts = fetchedClaude.map(Account.claude) + fetchedNative.map(Account.native) + fetchedShared.map(Account.shared)
        usage = fetchedUsage
        usageSummary = fetchedUsage.map(Self.makeUsageSummary)
        failedSources = failures
        state = failures.count == 4 ? .failed : .loaded
    }

    private static func normalizedTeamID(_ teamID: String?) -> String? {
        guard let teamID else { return nil }
        let value = teamID.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func makeUsageSummary(_ usage: TeamMachineUsage) -> UsageSummary {
        var totalTokens = 0
        var totalValue = 0.0
        var maximumTokens = 0
        for machine in usage.machines {
            totalTokens += machine.totals.totalTokens
            totalValue += machine.totals.apiEquivalentUsd
            maximumTokens = max(maximumTokens, machine.totals.totalTokens)
        }
        return UsageSummary(totalTokens: totalTokens, totalValue: totalValue, maximumTokens: max(1, maximumTokens))
    }

    private static func decodeClaudeAccounts(_ value: JSONValue) throws -> [ClaudeAccount] {
        guard case .object(let object) = value,
              case .array(let values) = object["accounts"] else {
            throw DecodeFailure(field: "accounts")
        }
        return try values.map { value in
            guard case .object(let object) = value,
                  let id = string(object["id"]),
                  let kind = string(object["kind"]) else {
                throw DecodeFailure(field: "account")
            }
            return ClaudeAccount(
                id: id,
                kind: kind,
                label: string(object["label"]) ?? "",
                identifier: string(object["identifier"]) ?? "",
                region: string(object["region"]),
                state: string(object["state"]) ?? "active",
                cooldownUntil: date(object["cooldownUntil"]),
                lastFailureCode: string(object["lastFailureCode"]),
                lastUsedAt: date(object["lastUsedAt"])
            )
        }
    }

    private static func decodeSharedAccounts(_ values: [JSONValue]) throws -> [SharedAccount] {
        try values.map { value in
            guard case .object(let object) = value,
                  let id = string(object["id"]) else {
                throw DecodeFailure(field: "account id")
            }
            var healthOK: Bool?
            var healthMessage: String?
            if case .object(let health)? = object["health"] {
                if case .bool(let value)? = health["ok"] { healthOK = value }
                healthMessage = string(health["message"])
            }
            return SharedAccount(
                id: id,
                kind: string(object["kind"]) ?? string(object["provider"]) ?? "account",
                label: string(object["label"]) ?? "",
                createdAt: date(object["createdAt"]),
                healthOK: healthOK,
                healthMessage: healthMessage
            )
        }
    }

    private static func decodeNativeAccounts(_ value: JSONValue) throws -> [NativeAccount] {
        guard case .object(let object) = value,
              case .array(let values) = object["accounts"] else {
            throw DecodeFailure(field: "native accounts")
        }
        return try values.map { value in
            guard case .object(let object) = value,
                  let id = string(object["id"]),
                  let provider = string(object["provider"]) else {
                throw DecodeFailure(field: "native account")
            }
            let sessions: Int
            switch object["activeSessions"] {
            case .int(let value): sessions = Int(clamping: value)
            case .double(let value): sessions = Int(value)
            default: sessions = 0
            }
            return NativeAccount(
                id: id,
                provider: provider,
                providerAccountID: string(object["providerAccountId"]) ?? "",
                label: string(object["label"]) ?? "",
                state: string(object["state"]) ?? "active",
                cooldownUntil: date(object["cooldownUntil"]),
                lastFailureCode: string(object["lastFailureCode"]),
                activeSessions: max(0, sessions)
            )
        }
    }

    private static func string(_ value: JSONValue?) -> String? {
        guard case .string(let string)? = value else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func date(_ value: JSONValue?) -> Date? {
        guard let string = string(value) else { return nil }
        return fractionalISO8601Formatter.date(from: string) ?? ISO8601Formatter.date(from: string)
    }
}
