import CMUXMobileCore
import CmuxSettings
import Foundation

enum MobileHostIdentity {
    private static let deviceIDKey = "mobileHost.deviceID"
    private static let sharedDeviceIDFileName = "mobile-host-device-id"
    private static let stableBundleIdentifier = "com.cmuxterm.app"
    private static let maximumDisplayNameUTF16Length = 128
    private static let maximumDisplayedBuildTagUTF16Length = 64

    static func deviceID() -> String {
        let stableDefaults = Bundle.main.bundleIdentifier == stableBundleIdentifier
            ? nil
            : UserDefaults(suiteName: stableBundleIdentifier)
        return deviceID(
            defaults: .standard,
            sharedIDURL: defaultSharedDeviceIDURL(),
            stableDefaults: stableDefaults,
            bundleIdentifier: Bundle.main.bundleIdentifier
        )
    }

    static func deviceID(
        defaults: UserDefaults,
        sharedIDURL: URL?,
        stableDefaults: UserDefaults? = nil,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> String {
        if let id = readSharedDeviceID(from: sharedIDURL) {
            defaults.set(id, forKey: deviceIDKey)
            return id
        }

        if shouldPreferStableDefaults(bundleIdentifier: bundleIdentifier),
           let id = normalizedID(stableDefaults?.string(forKey: deviceIDKey)) {
            return settleSharedDeviceID(id, defaults: defaults, sharedIDURL: sharedIDURL)
        }

        if let id = normalizedID(defaults.string(forKey: deviceIDKey)) {
            return settleSharedDeviceID(id, defaults: defaults, sharedIDURL: sharedIDURL)
        }

        let generated = cmxCanonicalDeviceID(UUID().uuidString)
        return settleSharedDeviceID(generated, defaults: defaults, sharedIDURL: sharedIDURL)
    }

    private static func defaultSharedDeviceIDURL(fileManager: FileManager = .default) -> URL? {
        guard let appSupport = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            return nil
        }
        let directory = appSupport.appendingPathComponent("cmux", isDirectory: true)
        if !fileManager.fileExists(atPath: directory.path) {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory.appendingPathComponent(sharedDeviceIDFileName)
    }

    private static func shouldPreferStableDefaults(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier,
              !bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return bundleIdentifier != stableBundleIdentifier
    }

    private static func normalizedID(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard UUID(uuidString: trimmed) != nil else { return nil }
        return cmxCanonicalDeviceID(trimmed)
    }

    private static func readSharedDeviceID(from url: URL?) -> String? {
        guard let url,
              let existing = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        return normalizedID(existing)
    }

    private static func settleSharedDeviceID(_ candidate: String, defaults: UserDefaults, sharedIDURL: URL?) -> String {
        let candidate = cmxCanonicalDeviceID(candidate)
        guard let sharedIDURL else {
            defaults.set(candidate, forKey: deviceIDKey)
            return candidate
        }
        try? FileManager.default.createDirectory(
            at: sharedIDURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = Data(candidate.utf8)
        if !FileManager.default.createFile(atPath: sharedIDURL.path, contents: data) {
            if let winner = readSharedDeviceID(from: sharedIDURL) {
                defaults.set(winner, forKey: deviceIDKey)
                return winner
            }
            try? data.write(to: sharedIDURL, options: .atomic)
        }
        let settled = readSharedDeviceID(from: sharedIDURL) ?? candidate
        defaults.set(settled, forKey: deviceIDKey)
        return settled
    }

    /// Stable physical-device name. Device-level registry and backup rows use
    /// this value because they are shared by every tagged app instance.
    static func baseDisplayName() -> String? {
        baseDisplayName(defaults: .standard)
    }

    static func baseDisplayName(defaults: UserDefaults) -> String? {
        baseDisplayName(defaults: defaults, hostName: Host.current().localizedName)
    }

    static func baseDisplayName(
        defaults: UserDefaults,
        hostName: String?
    ) -> String? {
        let key = SettingCatalog().mobile.iOSPairingDisplayName.userDefaultsKey
        let baseName: String?
        if let override = defaults.string(forKey: key) {
            let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                baseName = trimmed
            } else {
                baseName = hostName
            }
        } else {
            baseName = hostName
        }

        guard let baseName else { return nil }
        let trimmedName = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty ? nil : trimmedName
    }

    /// Per-app-instance name sent through tickets, authenticated status, and
    /// presence. Tagged DEBUG builds append their canonical launch tag while
    /// release and untagged builds keep the stable base name.
    static func instanceDisplayName() -> String? {
        instanceDisplayName(defaults: .standard)
    }

    static func instanceDisplayName(defaults: UserDefaults) -> String? {
        instanceDisplayName(
            defaults: defaults,
            hostName: Host.current().localizedName,
            buildTag: currentDebugBuildTag()
        )
    }

    static func instanceDisplayName(
        defaults: UserDefaults,
        hostName: String?,
        buildTag: String?
    ) -> String? {
        guard let trimmedName = baseDisplayName(defaults: defaults, hostName: hostName) else {
            return nil
        }
        let trimmedTag = buildTag?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedTag.isEmpty, trimmedTag != "default" else {
            return trimmedName
        }
        let originalSuffix = " (\(trimmedTag))"
        let unsuffixedName = trimmedName.hasSuffix(originalSuffix)
            ? String(trimmedName.dropLast(originalSuffix.count))
            : trimmedName
        let displayedTag = prefix(
            of: trimmedTag,
            fittingUTF16Length: maximumDisplayedBuildTagUTF16Length
        )
        let suffix = " (\(displayedTag))"
        let baseNameBudget = maximumDisplayNameUTF16Length - suffix.utf16.count
        let boundedName = prefix(of: unsuffixedName, fittingUTF16Length: baseNameBudget)
        return boundedName + suffix
    }

    /// Canonical app-instance tag used by registry and presence. This is the
    /// same launch tag or release channel that owns the socket and bundle
    /// identity.
    static func instanceTag() -> String {
        instanceTag(
            environment: ProcessInfo.processInfo.environment,
            bundleIdentifier: Bundle.main.bundleIdentifier
        )
    }

    /// Resolves the app-instance tag from explicit launch metadata first, then
    /// from the bundle channel. Stable keeps the historical `"default"` tag;
    /// Nightly and Staging must be distinct now that every app bundle on one
    /// Mac intentionally shares the same physical device identifier.
    static func instanceTag(
        environment: [String: String],
        bundleIdentifier: String?
    ) -> String {
        if let launchTag = SocketControlSettings.launchTag(environment: environment) {
            return launchTag
        }

        let normalizedBundleID = bundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let releaseCandidateBundleID = stableBundleIdentifier + ".rc"
        if normalizedBundleID == releaseCandidateBundleID {
            return "rc"
        }
        if normalizedBundleID.hasPrefix(releaseCandidateBundleID + ".") {
            let suffix = String(normalizedBundleID.dropFirst(releaseCandidateBundleID.count + 1))
            return SocketPathMarkerFiles.sanitizeSocketSlug(suffix) ?? "rc"
        }

        switch SocketPathMarkerFiles.variant(
            bundleIdentifier: normalizedBundleID,
            environment: environment
        ) {
        case .stable:
            return "default"
        case .nightly(let slug):
            return slug ?? "nightly"
        case .staging(let slug):
            return slug ?? "staging"
        case .dev(let slug):
            return slug ?? "dev"
        }
    }

    /// Returns the longest whole-character prefix that fits a UTF-16 wire limit.
    /// The cloud presence and paired-Mac APIs cap display names at 128 UTF-16
    /// code units, matching JavaScript's `String.length` measurement.
    private static func prefix(of value: String, fittingUTF16Length limit: Int) -> String {
        guard limit > 0 else { return "" }
        var result = ""
        var length = 0
        for character in value {
            let characterLength = String(character).utf16.count
            guard length + characterLength <= limit else { break }
            result.append(character)
            length += characterLength
        }
        return result
    }

    private static func currentDebugBuildTag() -> String? {
        #if DEBUG
        let tag = instanceTag()
        return tag == "default" ? nil : tag
        #else
        nil
        #endif
    }
}
