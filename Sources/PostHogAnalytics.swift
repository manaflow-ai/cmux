import AppKit
import Foundation
import PostHog
import Security

@MainActor
final class PostHogAnalytics {
    static let shared = PostHogAnalytics()

    // The PostHog project API key is intentionally embedded in the app (it's a public key).
    // Replace with the real key for the cmux PostHog project.
    private let apiKey = "phc_opOVu7oFzR9wD3I6ZahFGOV2h3mqGpl5EHyQvmHciDP"

    // PostHog Cloud US default (matches other cmux properties).
    private let host = "https://us.i.posthog.com"

    private let lastActiveDayUTCKey = "posthog.lastActiveDayUTC"

    private let keychainService = "com.cmuxterm.posthog"
    private let keychainAccount = "distinct_id"

    private var didStart = false
    private var activeCheckTimer: Timer?

    private var isEnabled: Bool {
#if DEBUG
        // Avoid polluting production analytics while iterating locally.
        return ProcessInfo.processInfo.environment["CMUX_POSTHOG_ENABLE"] == "1"
#else
        return !apiKey.isEmpty && apiKey != "REPLACE_WITH_POSTHOG_PUBLIC_KEY"
#endif
    }

    func startIfNeeded() {
        guard !didStart else { return }
        guard isEnabled else { return }

        let config = PostHogConfig(apiKey: apiKey, host: host)
        config.captureApplicationLifecycleEvents = false
        config.captureScreenViews = false
#if DEBUG
        config.debug = ProcessInfo.processInfo.environment["CMUX_POSTHOG_DEBUG"] == "1"
#endif

        PostHogSDK.shared.setup(config)

        // Tag every event so PostHog can distinguish desktop from web.
        PostHogSDK.shared.register(["platform": "cmuxterm"])

        // Keep a stable distinct id so DAU is "unique installs active" and doesn't churn.
        PostHogSDK.shared.identify(getOrCreateDistinctId())

        didStart = true

        // If the app stays in the foreground across midnight, `applicationDidBecomeActive`
        // won't fire again, so a periodic check avoids undercounting those users.
        activeCheckTimer?.invalidate()
        activeCheckTimer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard NSApp.isActive else { return }
            self.trackDailyActive(reason: "activeTimer")
        }
    }

    func trackDailyActive(reason: String) {
        startIfNeeded()
        guard didStart else { return }

        let today = utcDayString(Date())
        let defaults = UserDefaults.standard
        if defaults.string(forKey: lastActiveDayUTCKey) == today {
            return
        }

        defaults.set(today, forKey: lastActiveDayUTCKey)

        PostHogSDK.shared.capture("cmux_daily_active", properties: [
            "day_utc": today,
            "reason": reason,
        ])

        // For DAU we care more about delivery than batching.
        PostHogSDK.shared.flush()
    }

    func flush() {
        guard didStart else { return }
        PostHogSDK.shared.flush()
    }

    // MARK: - Distinct Id

    private func getOrCreateDistinctId() -> String {
        if let existing = readKeychainString(service: keychainService, account: keychainAccount),
           !existing.isEmpty {
            return existing
        }

        let fresh = UUID().uuidString
        if writeKeychainString(service: keychainService, account: keychainAccount, value: fresh) {
            return fresh
        }

        // Keychain can fail in some environments; fall back to a per-install id in defaults.
        let defaultsKey = "posthog.distinctId.fallback"
        if let existing = UserDefaults.standard.string(forKey: defaultsKey), !existing.isEmpty {
            return existing
        }
        UserDefaults.standard.set(fresh, forKey: defaultsKey)
        return fresh
    }

    private func readKeychainString(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func writeKeychainString(service: String, account: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess {
            return true
        }

        if status != errSecItemNotFound {
            return false
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    private func utcDayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
