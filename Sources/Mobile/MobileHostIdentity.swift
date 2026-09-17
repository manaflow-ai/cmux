import CMUXMobileCore
import CmuxFoundation
import CmuxSettings
import Foundation

enum MobileHostIdentity {
    private static let deviceIDKey = "mobileHost.deviceID"
    private static let sharedDeviceIDFileName = "mobile-host-device-id"
    private static let stableBundleIdentifier = "com.cmuxterm.app"
    private static let maximumDisplayNameUTF16Length = 128
    private static let maximumDisplayedBuildTagUTF16Length = 64
    /// Publishes the initialized snapshot and elects its defaults-mirror writer.
    /// A synchronous compare-and-set lets reentrant readers avoid joining
    /// UserDefaults notification delivery on another thread.
    private static let deviceIDReady = AtomicBooleanGate(false)

    /// Process-stable host identity used by synchronous transport and terminal paths.
    ///
    /// Swift initializes this constant once, so the filesystem-backed migration
    /// runs at most once per app process. After initialization, ``deviceID()``
    /// returns the immutable snapshot without locking or disk access. The
    /// overload below remains the testable resolver for persistence migration.
    private static let cachedDeviceID: String = {
        let stableDefaults = Bundle.main.bundleIdentifier == stableBundleIdentifier
            ? nil
            : UserDefaults(suiteName: stableBundleIdentifier)
        return resolveDeviceID(
            defaults: .standard,
            sharedIDURL: defaultSharedDeviceIDURL(),
            stableDefaults: stableDefaults,
            bundleIdentifier: Bundle.main.bundleIdentifier
        )
    }()

    /// Returns the process-stable host identity without repeating filesystem work.
    static func deviceID() -> String {
        let value = cachedDeviceID
        // Defaults may synchronously deliver an observer on the main queue.
        // Publish after leaving the once initializer, before that observer can
        // reenter deviceID() and wait on the thread performing this write.
        if deviceIDReady.compareExchange(expected: false, desired: true) {
            persistDeviceIDIfNeeded(value, defaults: .standard)
        }
        return value
    }

    /// Returns the identity after its immutable snapshot has been published,
    /// without joining defaults notification delivery. This check never touches
    /// the lazy snapshot while it is cold.
    static func deviceIDIfReady() -> String? {
        guard deviceIDReady.loadAcquire() else { return nil }
        return cachedDeviceID
    }

    /// Resolves the identity on a utility task so migration I/O cannot occupy
    /// the main actor. Swift still initializes ``cachedDeviceID`` exactly once.
    static func prewarm() async {
        await Task.detached(priority: .utility) {
            _ = deviceID()
        }.value
    }

    static func deviceID(
        defaults: UserDefaults,
        sharedIDURL: URL?,
        stableDefaults: UserDefaults? = nil,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> String {
        let id = resolveDeviceID(
            defaults: defaults,
            sharedIDURL: sharedIDURL,
            stableDefaults: stableDefaults,
            bundleIdentifier: bundleIdentifier
        )
        persistDeviceIDIfNeeded(id, defaults: defaults)
        return id
    }

    /// Settles the authoritative identity without posting defaults notifications.
    private static func resolveDeviceID(
        defaults: UserDefaults,
        sharedIDURL: URL?,
        stableDefaults: UserDefaults?,
        bundleIdentifier: String?
    ) -> String {
        if let id = readSharedDeviceID(from: sharedIDURL) {
            return id
        }

        if shouldPreferStableDefaults(bundleIdentifier: bundleIdentifier),
           let id = normalizedID(stableDefaults?.string(forKey: deviceIDKey)) {
            return settleSharedDeviceID(id, sharedIDURL: sharedIDURL)
        }

        if let id = normalizedID(defaults.string(forKey: deviceIDKey)) {
            return settleSharedDeviceID(id, sharedIDURL: sharedIDURL)
        }

        let generated = cmxCanonicalDeviceID(UUID().uuidString)
        return settleSharedDeviceID(generated, sharedIDURL: sharedIDURL)
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

    private static func persistDeviceIDIfNeeded(_ id: String, defaults: UserDefaults) {
        let stored = normalizedID(defaults.string(forKey: deviceIDKey))
        guard stored != id else { return }
        defaults.set(id, forKey: deviceIDKey)
    }

    private static func settleSharedDeviceID(_ candidate: String, sharedIDURL: URL?) -> String {
        let candidate = cmxCanonicalDeviceID(candidate)
        guard let sharedIDURL else {
            return candidate
        }
        try? FileManager.default.createDirectory(
            at: sharedIDURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = Data(candidate.utf8)
        if !FileManager.default.createFile(atPath: sharedIDURL.path, contents: data) {
            if let winner = readSharedDeviceID(from: sharedIDURL) {
                return winner
            }
            try? data.write(to: sharedIDURL, options: .atomic)
        }
        return readSharedDeviceID(from: sharedIDURL) ?? candidate
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
    /// Nightly, RC, and Staging must be distinct now that every app bundle on one
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
        switch SocketPathMarkerFiles.variant(
            bundleIdentifier: normalizedBundleID,
            environment: environment
        ) {
        case .stable:
            return "default"
        case .nightly(let slug):
            return slug ?? "nightly"
        case .rc(let slug):
            return slug ?? "rc"
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
