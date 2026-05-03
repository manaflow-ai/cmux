import Foundation

// MARK: - Usage Windows

struct ProviderUsageWindows: Sendable {
    let session: ProviderUsageWindow
    let week: ProviderUsageWindow
}

struct ProviderUsageWindow: Sendable {
    let utilization: Int        // 0..100, "% used"
    let resetsAt: Date?
    let windowSeconds: TimeInterval  // 18000 for session, 604800 for week
}

// MARK: - Incidents

struct ProviderIncident: Identifiable, Sendable {
    let id: String
    let name: String
    let status: String
    let impact: String
    let updatedAt: Date?
}

// MARK: - Usage Snapshot

struct ProviderUsageSnapshot: Sendable {
    let accountId: UUID
    let providerId: String
    let displayName: String
    let session: ProviderUsageWindow
    let week: ProviderUsageWindow
    let fetchedAt: Date
}

// MARK: - Credential Field

struct CredentialField: Identifiable, Sendable {
    let id: String              // dictionary key, e.g. "sessionKey", "orgId", "apiKey"
    let label: String           // localized
    let placeholder: String
    let isSecret: Bool          // SecureField vs TextField
    let helpText: String?       // shown under the field
    let validate: (@Sendable (String) -> Bool)?
}

// MARK: - Usage Provider

struct UsageProvider: Identifiable, Sendable {
    let id: String              // "claude" | "codex" | ...
    let displayName: String     // "Claude" | "Codex"
    let keychainService: String // "com.cmuxterm.app.claude-accounts"
    let credentialFields: [CredentialField]
    let statusPageURL: URL?     // for the popover "open status page" button
    let statusSectionTitle: String  // localized popover header, e.g. "Claude.ai status"
    let helpDocURL: URL?        // for the editor sheet help link
    let fetchUsage: @Sendable (ProviderSecret) async throws -> ProviderUsageWindows
    let fetchStatus: (@Sendable () async throws -> [ProviderIncident])?
}
