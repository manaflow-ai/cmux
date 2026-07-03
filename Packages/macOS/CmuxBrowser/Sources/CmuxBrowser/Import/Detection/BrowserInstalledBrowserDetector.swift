public import Foundation
import AppKit

/// Scans the current Mac for installed browsers and their importable source
/// profiles, returning ranked ``InstalledBrowserCandidate`` values.
///
/// Detection is stateless: it reads only the filesystem (through the injected
/// `FileManager`) and an injected bundle-lookup seam, so it can be exercised
/// against fixture directories in tests without touching the real system.
public struct BrowserInstalledBrowserDetector {
    /// A seam that resolves an installed application URL for a bundle
    /// identifier (backed by `NSWorkspace` in production).
    public typealias BundleLookup = @Sendable (String) -> URL?

    private let homeDirectoryURL: URL
    private let bundleLookup: BundleLookup
    private let applicationSearchDirectories: [URL]
    private let fileManager: FileManager

    /// Creates a detector bound to a home directory and discovery seams.
    ///
    /// - Parameters:
    ///   - homeDirectoryURL: The home directory to scan; defaults to the
    ///     current user's home.
    ///   - bundleLookup: Resolves an application URL for a bundle identifier;
    ///     defaults to `NSWorkspace.shared`.
    ///   - applicationSearchDirectories: Directories searched for `.app`
    ///     bundles; defaults to the standard macOS application locations.
    ///   - fileManager: File manager used for all filesystem checks.
    public init(
        homeDirectoryURL: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
        bundleLookup: BundleLookup? = nil,
        applicationSearchDirectories: [URL]? = nil,
        fileManager: FileManager = .default
    ) {
        self.homeDirectoryURL = homeDirectoryURL
        self.bundleLookup = bundleLookup ?? { bundleIdentifier in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        }
        self.applicationSearchDirectories = applicationSearchDirectories
            ?? Self.defaultApplicationSearchDirectories(homeDirectoryURL: homeDirectoryURL)
        self.fileManager = fileManager
    }

    /// Scans for installed browsers using this detector's configured seams.
    ///
    /// - Returns: Detected-browser candidates ranked by detection score, then
    ///   descriptor tier, then display name.
    public func detectInstalledBrowsers() -> [InstalledBrowserCandidate] {
        let candidates = BrowserImportBrowserDescriptor.allBrowserDescriptors.compactMap { descriptor -> InstalledBrowserCandidate? in
            let appDetection = detectApplication(descriptor: descriptor)

            let dataDetection = detectData(
                descriptor: descriptor,
                appBundleIdentifier: appDetection.bundleIdentifier
            )

            if appDetection.url == nil,
               !descriptor.supportsDataOnlyDetection {
                return nil
            }

            let hasData = dataDetection.dataRootURL != nil || !dataDetection.profiles.isEmpty || !dataDetection.artifactHits.isEmpty
            guard appDetection.url != nil || hasData else {
                return nil
            }

            var score = 0
            if appDetection.url != nil {
                score += 80
            }
            if dataDetection.dataRootURL != nil {
                score += 24
            }
            score += min(24, dataDetection.profiles.count * 6)
            score += min(16, dataDetection.artifactHits.count * 4)

            var signals: [String] = []
            signals.append(contentsOf: appDetection.signals)
            if let root = dataDetection.dataRootURL {
                signals.append("data:\(root.lastPathComponent)")
            }
            if !dataDetection.profiles.isEmpty {
                signals.append("profiles:\(dataDetection.profiles.count)")
            }
            if !dataDetection.artifactHits.isEmpty {
                signals.append(contentsOf: dataDetection.artifactHits.map { "artifact:\($0)" })
            }

            return InstalledBrowserCandidate(
                descriptor: descriptor,
                resolvedFamily: dataDetection.family,
                homeDirectoryURL: homeDirectoryURL,
                appURL: appDetection.url,
                dataRootURL: dataDetection.dataRootURL,
                profiles: dataDetection.profiles,
                detectionSignals: signals,
                detectionScore: score
            )
        }

        return candidates.sorted { lhs, rhs in
            if lhs.detectionScore != rhs.detectionScore {
                return lhs.detectionScore > rhs.detectionScore
            }
            if lhs.descriptor.tier != rhs.descriptor.tier {
                return lhs.descriptor.tier < rhs.descriptor.tier
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    /// Builds a localized one-line summary of detected browsers for hint UI.
    ///
    /// An instance method (not a static namespace member) so call sites invoke it
    /// on a held detector. It does not read this detector's seams; it formats the
    /// candidates passed in.
    ///
    /// - Parameters:
    ///   - browsers: The detected browser candidates.
    ///   - limit: Maximum number of names to list before summarizing the rest.
    /// - Returns: A localized summary string.
    public func summaryText(for browsers: [InstalledBrowserCandidate], limit: Int = 4) -> String {
        guard !browsers.isEmpty else {
            return String(
                localized: "browser.import.detected.none",
                defaultValue: "No supported browsers detected."
            )
        }
        let names = browsers.map(\.displayName)
        if names.count <= limit {
            return String(
                format: String(
                    localized: "browser.import.detected.all",
                    defaultValue: "Detected: %@."
                ),
                names.joined(separator: ", ")
            )
        }
        let shown = names.prefix(limit).joined(separator: ", ")
        let remaining = names.count - limit
        if remaining == 1 {
            return String(
                format: String(
                    localized: "browser.import.detected.more.one",
                    defaultValue: "Detected: %@, +1 more."
                ),
                shown
            )
        }
        return String(
            format: String(
                localized: "browser.import.detected.more.other",
                defaultValue: "Detected: %@, +%ld more."
            ),
            shown,
            remaining
        )
    }

    private func detectApplication(
        descriptor: BrowserImportBrowserDescriptor
    ) -> (url: URL?, signals: [String], bundleIdentifier: String?) {
        for knownBundleIdentifier in descriptor.bundleIdentifiers {
            if let appURL = bundleLookup(knownBundleIdentifier) {
                return (appURL, ["bundle:\(knownBundleIdentifier)"], Self.bundleIdentifier(for: appURL) ?? knownBundleIdentifier)
            }
        }

        for appName in descriptor.appNames {
            for directory in applicationSearchDirectories {
                let appURL = directory.appendingPathComponent(appName, isDirectory: true)
                if fileManager.fileExists(atPath: appURL.path) {
                    return (appURL, ["app:\(appName)"], Self.bundleIdentifier(for: appURL))
                }
            }
        }

        return (nil, [], nil)
    }

    private func detectData(
        descriptor: BrowserImportBrowserDescriptor,
        appBundleIdentifier: String?
    ) -> (dataRootURL: URL?, family: BrowserImportEngineFamily, profiles: [InstalledBrowserProfile], artifactHits: [String]) {
        var bestRootURL: URL?
        var bestFamily = descriptor.family
        var bestProfiles: [InstalledBrowserProfile] = []
        var bestArtifacts: [String] = []
        let candidateRootPaths = Self.candidateDataRootRelativePaths(
            descriptor: descriptor,
            appBundleIdentifier: appBundleIdentifier
        )

        for relativePath in candidateRootPaths {
            let rootURL = homeDirectoryURL.appendingPathComponent(relativePath, isDirectory: true)
            guard fileManager.fileExists(atPath: rootURL.path) else { continue }

            let detectedProfiles = detectProfiles(descriptor: descriptor, rootURL: rootURL)

            let score = Self.scoreProfileDetection(
                family: detectedProfiles.family,
                profiles: detectedProfiles.profiles,
                preferredFamily: descriptor.family
            ) + 8
            let currentScore = Self.scoreProfileDetection(
                family: bestFamily,
                profiles: bestProfiles,
                preferredFamily: descriptor.family
            ) + (bestRootURL == nil ? 0 : 8)
            if score > currentScore {
                bestRootURL = rootURL
                bestFamily = detectedProfiles.family
                bestProfiles = detectedProfiles.profiles
            }
        }

        var artifactHits: [String] = []
        for relativePath in descriptor.dataArtifactRelativePaths {
            let artifactURL = homeDirectoryURL.appendingPathComponent(relativePath, isDirectory: false)
            if fileManager.fileExists(atPath: artifactURL.path) {
                artifactHits.append(artifactURL.lastPathComponent)
            }
        }

        if !artifactHits.isEmpty {
            bestArtifacts = artifactHits
            if bestRootURL == nil,
               let rootPath = candidateRootPaths.first {
                let rootURL = homeDirectoryURL.appendingPathComponent(rootPath, isDirectory: true)
                if fileManager.fileExists(atPath: rootURL.path) {
                    bestRootURL = rootURL
                }
            }
        }

        if bestProfiles.isEmpty, let bestRootURL {
            bestProfiles = [
                InstalledBrowserProfile(
                    displayName: String(localized: "browser.profile.default", defaultValue: "Default"),
                    rootURL: bestRootURL,
                    isDefault: true
                )
            ]
        }

        return (
            dataRootURL: bestRootURL,
            family: bestFamily,
            profiles: Self.sortProfiles(Self.dedupedProfiles(bestProfiles)),
            artifactHits: bestArtifacts
        )
    }

    private func detectProfiles(
        descriptor: BrowserImportBrowserDescriptor,
        rootURL: URL
    ) -> (family: BrowserImportEngineFamily, profiles: [InstalledBrowserProfile]) {
        let candidates: [(BrowserImportEngineFamily, [InstalledBrowserProfile])] = [
            (.chromium, chromiumProfiles(descriptor: descriptor, rootURL: rootURL)),
            (.firefox, firefoxProfiles(rootURL: rootURL)),
            (.webkit, webKitProfiles(descriptor: descriptor, rootURL: rootURL)),
        ]

        return candidates.max { lhs, rhs in
            let lhsScore = Self.scoreProfileDetection(
                family: lhs.0,
                profiles: lhs.1,
                preferredFamily: descriptor.family
            )
            let rhsScore = Self.scoreProfileDetection(
                family: rhs.0,
                profiles: rhs.1,
                preferredFamily: descriptor.family
            )
            if lhsScore != rhsScore {
                return lhsScore < rhsScore
            }
            return lhs.0.rawValue > rhs.0.rawValue
        } ?? (descriptor.family, [])
    }

    private static func bundleIdentifier(for appURL: URL) -> String? {
        Bundle(url: appURL)?.bundleIdentifier
    }

    private static func candidateDataRootRelativePaths(
        descriptor: BrowserImportBrowserDescriptor,
        appBundleIdentifier: String?
    ) -> [String] {
        var result: [String] = []
        var seen = Set<String>()

        func append(_ relativePath: String) {
            if seen.insert(relativePath).inserted {
                result.append(relativePath)
            }
        }

        for relativePath in descriptor.dataRootRelativePaths {
            append(relativePath)
        }

        let bundleIdentifiers = [appBundleIdentifier].compactMap { $0 } + descriptor.bundleIdentifiers
        for bundleIdentifier in bundleIdentifiers {
            append("Library/Application Support/\(bundleIdentifier)")
            append("Library/Containers/\(bundleIdentifier)/Data/Library/Application Support/\(bundleIdentifier)")
        }

        return result
    }

    private static func scoreProfileDetection(
        family: BrowserImportEngineFamily,
        profiles: [InstalledBrowserProfile],
        preferredFamily: BrowserImportEngineFamily
    ) -> Int {
        var score = profiles.count * 10
        if family == preferredFamily {
            score += 3
        }
        if profiles.contains(where: \.isDefault) {
            score += 1
        }
        return score
    }

    private func chromiumProfiles(descriptor: BrowserImportBrowserDescriptor, rootURL: URL) -> [InstalledBrowserProfile] {
        let nameMap = Self.chromiumProfileNameMap(rootURL: rootURL)
        var profiles: [InstalledBrowserProfile] = []
        if looksLikeChromiumProfile(rootURL: rootURL, allowNetworkCookies: false) {
            profiles.append(
                InstalledBrowserProfile(
                    displayName: Self.chromiumProfileDisplayName(
                        directoryName: rootURL.lastPathComponent,
                        nameMap: nameMap,
                        isDefault: true
                    ),
                    rootURL: rootURL,
                    isDefault: true
                )
            )
        }

        let children = (try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        for child in children {
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let name = child.lastPathComponent
            guard name != "Network" else { continue }
            guard looksLikeChromiumProfile(rootURL: child, allowNetworkCookies: true) else { continue }
            guard name == "Default" || name.hasPrefix("Profile ") || name.hasPrefix("Guest Profile") ||
                name.hasPrefix("Person ") || nameMap[name] != nil || descriptor.id == "arc" else { continue }
            profiles.append(
                InstalledBrowserProfile(
                    displayName: Self.chromiumProfileDisplayName(
                        directoryName: name,
                        nameMap: nameMap,
                        isDefault: name == "Default"
                    ),
                    rootURL: child,
                    isDefault: name == "Default"
                )
            )
        }

        return Self.sortProfiles(Self.dedupedProfiles(profiles))
    }

    private func firefoxProfiles(rootURL: URL) -> [InstalledBrowserProfile] {
        var profiles = firefoxProfilesFromINI(rootURL: rootURL)

        let likelyProfileRoots = [
            rootURL.appendingPathComponent("Profiles", isDirectory: true),
            rootURL,
        ]

        for directory in likelyProfileRoots where fileManager.fileExists(atPath: directory.path) {
            let children = (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for child in children {
                guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                if looksLikeFirefoxProfile(rootURL: child) {
                    let directoryName = child.lastPathComponent
                    profiles.append(
                        InstalledBrowserProfile(
                            displayName: directoryName,
                            rootURL: child,
                            isDefault: directoryName.localizedCaseInsensitiveContains("default")
                        )
                    )
                }
            }
        }

        return Self.sortProfiles(Self.dedupedProfiles(profiles))
    }

    private func firefoxProfilesFromINI(rootURL: URL) -> [InstalledBrowserProfile] {
        let iniURL = rootURL.appendingPathComponent("profiles.ini", isDirectory: false)
        guard let contents = try? String(contentsOf: iniURL, encoding: .utf8) else {
            return []
        }

        let sections = Self.parseINISections(contents: contents)
        var profiles: [InstalledBrowserProfile] = []
        for section in sections {
            guard let pathValue = section["Path"], !pathValue.isEmpty else { continue }
            let isRelative = section["IsRelative"] != "0"
            let profileURL: URL
            if isRelative {
                profileURL = rootURL.appendingPathComponent(pathValue, isDirectory: true)
            } else {
                profileURL = URL(fileURLWithPath: pathValue, isDirectory: true)
            }
            if looksLikeFirefoxProfile(rootURL: profileURL) {
                let displayName = section["Name"]?.trimmingCharacters(in: .whitespacesAndNewlines)
                profiles.append(
                    InstalledBrowserProfile(
                        displayName: (displayName?.isEmpty == false ? displayName! : profileURL.lastPathComponent),
                        rootURL: profileURL,
                        isDefault: section["Default"] == "1"
                    )
                )
            }
        }
        return profiles
    }

    private static func parseINISections(contents: String) -> [[String: String]] {
        var sections: [[String: String]] = []
        var current: [String: String] = [:]

        func flushCurrent() {
            if !current.isEmpty {
                sections.append(current)
                current.removeAll()
            }
        }

        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix(";") || trimmed.hasPrefix("#") {
                continue
            }
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                flushCurrent()
                continue
            }
            guard let separator = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            current[key] = value
        }
        flushCurrent()
        return sections
    }

    private func looksLikeChromiumProfile(rootURL: URL, allowNetworkCookies: Bool) -> Bool {
        let historyURL = rootURL.appendingPathComponent("History", isDirectory: false)
        let cookiesURL = rootURL.appendingPathComponent("Cookies", isDirectory: false)
        guard !fileManager.fileExists(atPath: historyURL.path), !fileManager.fileExists(atPath: cookiesURL.path) else { return true }
        let networkCookiesURL = rootURL.appendingPathComponent("Network", isDirectory: true).appendingPathComponent("Cookies", isDirectory: false)
        return allowNetworkCookies && fileManager.fileExists(atPath: networkCookiesURL.path)
    }

    private func looksLikeFirefoxProfile(rootURL: URL) -> Bool {
        let historyURL = rootURL.appendingPathComponent("places.sqlite", isDirectory: false)
        let cookiesURL = rootURL.appendingPathComponent("cookies.sqlite", isDirectory: false)
        return fileManager.fileExists(atPath: historyURL.path) || fileManager.fileExists(atPath: cookiesURL.path)
    }

    private func webKitProfiles(
        descriptor: BrowserImportBrowserDescriptor,
        rootURL: URL
    ) -> [InstalledBrowserProfile] {
        var profiles: [InstalledBrowserProfile] = []
        if looksLikeWebKitProfile(rootURL: rootURL) {
            profiles.append(
                InstalledBrowserProfile(
                    displayName: String(localized: "browser.profile.default", defaultValue: "Default"),
                    rootURL: rootURL,
                    isDefault: true
                )
            )
        }

        var profileRoots = [rootURL.appendingPathComponent("Profiles", isDirectory: true)]
        if descriptor.id == "safari" {
            profileRoots.append(
                homeDirectoryURL
                    .appendingPathComponent("Library", isDirectory: true)
                    .appendingPathComponent("Containers", isDirectory: true)
                    .appendingPathComponent("com.apple.Safari", isDirectory: true)
                    .appendingPathComponent("Data", isDirectory: true)
                    .appendingPathComponent("Library", isDirectory: true)
                    .appendingPathComponent("Safari", isDirectory: true)
                    .appendingPathComponent("Profiles", isDirectory: true)
            )
        }

        var profileIndex = 1
        for profileRoot in Self.dedupedCanonicalURLs(profileRoots) where fileManager.fileExists(atPath: profileRoot.path) {
            let children = (try? fileManager.contentsOfDirectory(
                at: profileRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for child in children {
                guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                guard looksLikeWebKitProfile(rootURL: child) else { continue }
                profiles.append(
                    InstalledBrowserProfile(
                        displayName: Self.webKitProfileDisplayName(
                            directoryName: child.lastPathComponent,
                            fallbackIndex: profileIndex
                        ),
                        rootURL: child,
                        isDefault: false
                    )
                )
                profileIndex += 1
            }
        }

        return Self.sortProfiles(Self.dedupedProfiles(profiles))
    }

    private static func chromiumProfileNameMap(rootURL: URL) -> [String: String] {
        let localStateURL = rootURL.appendingPathComponent("Local State", isDirectory: false)
        guard let data = try? Data(contentsOf: localStateURL),
              let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profileSection = jsonObject["profile"] as? [String: Any],
              let infoCache = profileSection["info_cache"] as? [String: Any] else {
            return [:]
        }

        var result: [String: String] = [:]
        for (directoryName, rawProfileInfo) in infoCache {
            guard let profileInfo = rawProfileInfo as? [String: Any],
                  let name = profileInfo["name"] as? String else {
                continue
            }
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedName.isEmpty {
                result[directoryName] = trimmedName
            }
        }
        return result
    }

    private static func chromiumProfileDisplayName(
        directoryName: String,
        nameMap: [String: String],
        isDefault: Bool
    ) -> String {
        if let mappedName = nameMap[directoryName], !mappedName.isEmpty {
            return mappedName
        }
        if isDefault {
            return String(localized: "browser.profile.default", defaultValue: "Default")
        }
        return directoryName
    }

    private func looksLikeWebKitProfile(rootURL: URL) -> Bool {
        let candidatePaths = [
            "History.db",
            "Cookies.binarycookies",
            "Cookies.sqlite",
            "WebsiteData",
            "LocalStorage",
        ]

        for candidatePath in candidatePaths {
            let url = rootURL.appendingPathComponent(candidatePath, isDirectory: candidatePath != "History.db" && candidatePath != "Cookies.binarycookies" && candidatePath != "Cookies.sqlite")
            if fileManager.fileExists(atPath: url.path) {
                return true
            }
        }
        return false
    }

    private static func webKitProfileDisplayName(directoryName: String, fallbackIndex: Int) -> String {
        if directoryName.caseInsensitiveCompare("Default") == .orderedSame {
            return String(localized: "browser.profile.default", defaultValue: "Default")
        }
        if UUID(uuidString: directoryName) != nil {
            return String(
                format: String(
                    localized: "browser.import.sourceProfile.fallback",
                    defaultValue: "Profile %ld"
                ),
                fallbackIndex
            )
        }
        return directoryName
    }

    private static func defaultApplicationSearchDirectories(homeDirectoryURL: URL) -> [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            homeDirectoryURL.appendingPathComponent("Applications", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Setapp", isDirectory: true),
            homeDirectoryURL.appendingPathComponent("Applications/Setapp", isDirectory: true),
        ]
    }

    private static func dedupedProfiles(_ profiles: [InstalledBrowserProfile]) -> [InstalledBrowserProfile] {
        var seen = Set<String>()
        var result: [InstalledBrowserProfile] = []
        for profile in profiles {
            if seen.insert(profile.id).inserted {
                result.append(profile)
            }
        }
        return result
    }

    private static func sortProfiles(_ profiles: [InstalledBrowserProfile]) -> [InstalledBrowserProfile] {
        profiles.sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault {
                return lhs.isDefault && !rhs.isDefault
            }
            let comparison = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            if comparison != .orderedSame {
                return comparison == .orderedAscending
            }
            return lhs.id < rhs.id
        }
    }

    private static func dedupedCanonicalURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for url in urls {
            let key = url.standardizedFileURL.resolvingSymlinksInPath().path
            if seen.insert(key).inserted {
                result.append(url)
            }
        }
        return result
    }
}
