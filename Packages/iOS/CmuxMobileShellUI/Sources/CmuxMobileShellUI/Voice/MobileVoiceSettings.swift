import Foundation
import Observation

/// User-tunable voice-mode preferences, persisted to an injected
/// ``UserDefaults`` exactly like ``MobileDisplaySettings`` (constructed once
/// at the composition root, injected through the environment, bound with
/// `@Bindable`).
///
/// The user's own OpenAI API key is the one value that does NOT live in
/// UserDefaults: it goes through ``MobileVoiceAPIKeyStoring`` (Keychain in
/// production, in-memory in tests).
@MainActor
@Observable
public final class MobileVoiceSettings {
    // UserDefaults is Apple-documented thread-safe; the synchronous read in
    // `init` and the write-through in `didSet` are safe nonisolated.
    private nonisolated(unsafe) let defaults: UserDefaults
    private let apiKeyStore: any MobileVoiceAPIKeyStoring
    /// Durable user-told notes injected into every voice session and edited
    /// through the orchestrator's memory tools. Lives here so the one
    /// injected settings object carries all voice persistence.
    public let voiceMemory: MobileVoiceMemory

    private static let enabledKey = "cmux.mobile.voice.enabled"
    private static let voiceNameKey = "cmux.mobile.voice.voiceName"
    private static let speakAgentRepliesKey = "cmux.mobile.voice.speakAgentReplies"
    private static let speakCodeBlocksKey = "cmux.mobile.voice.speakCodeBlocks"
    private static let speakToolActivityKey = "cmux.mobile.voice.speakToolActivity"
    private static let spokenReplyLengthKey = "cmux.mobile.voice.spokenReplyLength"
    private static let orchestratorBypassPermissionsKey =
        "cmux.mobile.voice.orchestratorBypassPermissions"

    /// The GPT-Live voices the picker offers, `marin` first as the API
    /// default. Voice is a session-creation-time choice, so changes apply to
    /// the next session.
    public static let availableVoices = [
        "marin", "quartz", "ripple", "vesper", "willow", "stone", "gleam",
        "meridian", "bossa", "tempo", "beacon", "delta", "cinder",
    ]

    /// How much of one agent reply is worth speaking, as a character budget
    /// handed to ``SpeakableTextOptions/maximumCharacters``.
    public enum SpokenReplyLength: String, CaseIterable, Sendable {
        case short
        case medium
        case long

        public var maximumCharacters: Int {
            switch self {
            case .short: return 350
            case .medium: return 700
            case .long: return 1_400
            }
        }
    }

    /// Master switch for the voice entrypoints (root orchestrator button and
    /// per-workspace voice button). Defaults to `true`.
    public var voiceModeEnabled: Bool {
        didSet { defaults.set(voiceModeEnabled, forKey: Self.enabledKey) }
    }

    /// The GPT-Live output voice. Assigning an unknown name falls back to the
    /// API default so a stale persisted value can never fail session start.
    public var voiceName: String {
        didSet {
            if !Self.availableVoices.contains(voiceName) { voiceName = "marin" }
            defaults.set(voiceName, forKey: Self.voiceNameKey)
        }
    }

    /// Whether terminal voice mode speaks the coding agent's replies at all.
    /// Off, the voice only converses about what to send; replies stay on
    /// screen. Defaults to `true`.
    public var speakAgentReplies: Bool {
        didSet { defaults.set(speakAgentReplies, forKey: Self.speakAgentRepliesKey) }
    }

    /// Whether short code blocks are read verbatim instead of summarized as
    /// "a code block of N lines". Defaults to `false`.
    public var speakCodeBlocks: Bool {
        didSet { defaults.set(speakCodeBlocks, forKey: Self.speakCodeBlocksKey) }
    }

    /// Whether tool runs (file edits, searches, command runs) are narrated as
    /// one-line summaries. Defaults to `false`: tool chatter drowns out the
    /// prose that matters.
    public var speakToolActivity: Bool {
        didSet { defaults.set(speakToolActivity, forKey: Self.speakToolActivityKey) }
    }

    /// The per-reply spoken length budget. Defaults to ``SpokenReplyLength/medium``.
    public var spokenReplyLength: SpokenReplyLength {
        didSet { defaults.set(spokenReplyLength.rawValue, forKey: Self.spokenReplyLengthKey) }
    }

    /// Bypass All Permissions: the orchestrator executes every tool,
    /// destructive ones included, without the on-screen approval card.
    /// Defaults to `false`.
    public var orchestratorBypassPermissions: Bool {
        didSet {
            defaults.set(
                orchestratorBypassPermissions,
                forKey: Self.orchestratorBypassPermissionsKey
            )
        }
    }

    /// The user's own OpenAI API key (bring-your-own-key). Read once from the
    /// key store at init; assignment writes through. Empty/whitespace clears.
    /// Voice sessions require it: the key goes straight from this device to
    /// OpenAI, and no cmux-operated service holds or mints a voice credential.
    public var userOpenAIAPIKey: String {
        didSet {
            let trimmed = userOpenAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed != userOpenAIAPIKey { userOpenAIAPIKey = trimmed }
            apiKeyStore.store(trimmed.isEmpty ? nil : trimmed)
        }
    }

    /// The filter options the current settings imply.
    public var speakableTextOptions: SpeakableTextOptions {
        SpeakableTextOptions(
            speakCodeBlocks: speakCodeBlocks,
            maximumCharacters: spokenReplyLength.maximumCharacters
        )
    }

    /// Creates the voice settings, seeding stored values from `defaults` and
    /// the key from `apiKeyStore`. Absent keys read as their defaults without
    /// a write.
    public init(
        defaults: UserDefaults = .standard,
        apiKeyStore: any MobileVoiceAPIKeyStoring = MobileVoiceKeychainAPIKeyStore()
    ) {
        self.defaults = defaults
        self.apiKeyStore = apiKeyStore
        self.voiceMemory = MobileVoiceMemory(defaults: defaults)
        self.voiceModeEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        let storedVoice = defaults.string(forKey: Self.voiceNameKey)
        self.voiceName = storedVoice.flatMap {
            Self.availableVoices.contains($0) ? $0 : nil
        } ?? "marin"
        self.speakAgentReplies = defaults.object(forKey: Self.speakAgentRepliesKey) as? Bool ?? true
        self.speakCodeBlocks = defaults.bool(forKey: Self.speakCodeBlocksKey)
        self.speakToolActivity = defaults.bool(forKey: Self.speakToolActivityKey)
        self.spokenReplyLength = defaults.string(forKey: Self.spokenReplyLengthKey)
            .flatMap(SpokenReplyLength.init(rawValue:)) ?? .medium
        self.orchestratorBypassPermissions =
            defaults.bool(forKey: Self.orchestratorBypassPermissionsKey)
        self.userOpenAIAPIKey = apiKeyStore.load() ?? ""
    }
}

/// Storage seam for the user's OpenAI API key. `nil` means no key.
public protocol MobileVoiceAPIKeyStoring: Sendable {
    func load() -> String?
    func store(_ key: String?)
}

/// Keychain-backed key storage: a generic-password item scoped to this app,
/// device-only (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — the key
/// must never migrate to another device through a backup).
public struct MobileVoiceKeychainAPIKeyStore: MobileVoiceAPIKeyStoring {
    private static let service = "dev.cmux.ios.voice.openai-api-key"

    public init() {}

    public func load() -> String? {
        var query = Self.baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty
        else { return nil }
        return key
    }

    public func store(_ key: String?) {
        guard let key, !key.isEmpty else {
            SecItemDelete(Self.baseQuery() as CFDictionary)
            return
        }
        let data = Data(key.utf8)
        var attributes = Self.baseQuery()
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            SecItemUpdate(
                Self.baseQuery() as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
        }
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
    }
}

/// In-memory key storage for tests and previews.
public final class MobileVoiceInMemoryAPIKeyStore: MobileVoiceAPIKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var key: String?

    public init(key: String? = nil) {
        self.key = key
    }

    public func load() -> String? {
        lock.withLock { key }
    }

    public func store(_ key: String?) {
        lock.withLock { self.key = key }
    }
}
