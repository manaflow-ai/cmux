import CoreServices
import Darwin
import Foundation

enum UpdateQuarantineRepairOutcome: Equatable {
    case skipped
    case notFound
    case notQuarantined
    case alreadyValid
    case repaired
}

struct UpdateQuarantineRepairResult {
    let outcome: UpdateQuarantineRepairOutcome
    let url: URL?
    let beforeRawValue: String?
    let afterRawValue: String?
}

enum UpdateQuarantineRepair {
    static let sparkleCacheDirectoryName = "org.sparkle-project.Sparkle"
    static let persistentDownloadsDirectoryName = "PersistentDownloads"
    static let installationDirectoryName = "Installation"

    private static let quarantineAttributeName = "com.apple.quarantine"

    static func sparkleHostName(for bundle: Bundle = .main, fileManager: FileManager = .default) -> String {
        for key in ["SUBundleName", "CFBundleDisplayName", kCFBundleNameKey as String] {
            if let value = bundle.object(forInfoDictionaryKey: key) as? String,
               !value.isEmpty {
                return value
            }
        }
        return (fileManager.displayName(atPath: bundle.bundlePath) as NSString).deletingPathExtension
    }

    static func persistentDownloadsRootURL(bundleIdentifier: String, cachesDirectory: URL? = nil) -> URL {
        let base = cachesDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent(sparkleCacheDirectoryName, isDirectory: true)
            .appendingPathComponent(persistentDownloadsDirectoryName, isDirectory: true)
    }

    static func installationRootURL(bundleIdentifier: String, cachesDirectory: URL? = nil) -> URL {
        let base = cachesDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent(sparkleCacheDirectoryName, isDirectory: true)
            .appendingPathComponent(installationDirectoryName, isDirectory: true)
    }

    static func locateDownloadedArchive(
        bundleIdentifier: String,
        hostName: String,
        versionString: String,
        cachesDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL? {
        let rootURL = persistentDownloadsRootURL(bundleIdentifier: bundleIdentifier, cachesDirectory: cachesDirectory)
        let expectedDirectoryName = (hostName.isEmpty || versionString.isEmpty) ? nil : "\(hostName) \(versionString)"

        if let exactMatch = newestItem(
            in: rootURL,
            fileManager: fileManager,
            skipPackageDescendants: true,
            matching: { url, values, _ in
            guard values.isRegularFile == true else { return false }
            guard let expectedDirectoryName else { return true }
            return url.deletingLastPathComponent().lastPathComponent == expectedDirectoryName
            }
        ) {
            return exactMatch
        }

        return newestItem(in: rootURL, fileManager: fileManager, skipPackageDescendants: true) { _, values, _ in
            values.isRegularFile == true
        }
    }

    static func locateExtractedApplication(
        bundleIdentifier: String,
        bundleName: String,
        cachesDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL? {
        let rootURL = installationRootURL(bundleIdentifier: bundleIdentifier, cachesDirectory: cachesDirectory)
        let expectedBundleName = bundleName.isEmpty ? nil : bundleName

        if let exactMatch = newestItem(
            in: rootURL,
            fileManager: fileManager,
            skipPackageDescendants: true,
            matching: { url, values, _ in
            guard values.isDirectory == true, url.pathExtension == "app" else { return false }
            guard let expectedBundleName else { return true }
            return url.lastPathComponent == expectedBundleName
            }
        ) {
            return exactMatch
        }

        return newestItem(in: rootURL, fileManager: fileManager, skipPackageDescendants: true) { url, values, _ in
            values.isDirectory == true && url.pathExtension == "app"
        }
    }

    static func repairDownloadedArchiveIfNeeded(
        hostName: String,
        versionString: String,
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
        cachesDirectory: URL? = nil,
        dataURL: URL? = nil
    ) throws -> UpdateQuarantineRepairResult {
        guard let bundleIdentifier = bundle.bundleIdentifier else {
            return .init(outcome: .skipped, url: nil, beforeRawValue: nil, afterRawValue: nil)
        }

        guard let archiveURL = locateDownloadedArchive(
            bundleIdentifier: bundleIdentifier,
            hostName: hostName,
            versionString: versionString,
            cachesDirectory: cachesDirectory,
            fileManager: fileManager
        ) else {
            return .init(outcome: .notFound, url: nil, beforeRawValue: nil, afterRawValue: nil)
        }

        return try repairQuarantineIfNeeded(
            at: archiveURL,
            agentBundleIdentifier: bundleIdentifier,
            agentName: sparkleHostName(for: bundle, fileManager: fileManager),
            dataURL: dataURL
        )
    }

    static func repairExtractedApplicationIfNeeded(
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
        cachesDirectory: URL? = nil,
        dataURL: URL? = nil
    ) throws -> UpdateQuarantineRepairResult {
        guard let bundleIdentifier = bundle.bundleIdentifier else {
            return .init(outcome: .skipped, url: nil, beforeRawValue: nil, afterRawValue: nil)
        }

        guard let appURL = locateExtractedApplication(
            bundleIdentifier: bundleIdentifier,
            bundleName: bundle.bundleURL.lastPathComponent,
            cachesDirectory: cachesDirectory,
            fileManager: fileManager
        ) else {
            return .init(outcome: .notFound, url: nil, beforeRawValue: nil, afterRawValue: nil)
        }

        return try repairQuarantineIfNeeded(
            at: appURL,
            agentBundleIdentifier: bundleIdentifier,
            agentName: sparkleHostName(for: bundle, fileManager: fileManager),
            dataURL: dataURL
        )
    }

    static func repairQuarantineIfNeeded(
        at url: URL,
        agentBundleIdentifier: String,
        agentName: String,
        dataURL: URL? = nil
    ) throws -> UpdateQuarantineRepairResult {
        let beforeRawValue = rawQuarantineAttribute(at: url)
        var resourceValues = try url.resourceValues(forKeys: [.quarantinePropertiesKey])
        var quarantineProperties = resourceValues.quarantineProperties ?? [:]

        let hasQuarantine = beforeRawValue != nil || !quarantineProperties.isEmpty
        guard hasQuarantine else {
            return .init(outcome: .notQuarantined, url: url, beforeRawValue: beforeRawValue, afterRawValue: beforeRawValue)
        }

        var didChange = false

        let existingBundleIdentifier = (quarantineProperties[kLSQuarantineAgentBundleIdentifierKey as String] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if existingBundleIdentifier != agentBundleIdentifier {
            quarantineProperties[kLSQuarantineAgentBundleIdentifierKey as String] = agentBundleIdentifier
            didChange = true
        }

        let existingAgentName = (quarantineProperties[kLSQuarantineAgentNameKey as String] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if existingAgentName != agentName {
            quarantineProperties[kLSQuarantineAgentNameKey as String] = agentName
            didChange = true
        }

        if quarantineProperties[kLSQuarantineTypeKey as String] == nil {
            quarantineProperties[kLSQuarantineTypeKey as String] = inferredQuarantineType(for: dataURL)
            didChange = true
        }

        if let dataURL, quarantineProperties[kLSQuarantineDataURLKey as String] == nil {
            quarantineProperties[kLSQuarantineDataURLKey as String] = dataURL
            didChange = true
        }

        if !didChange, let beforeRawValue, rawQuarantineNeedsLaunchServicesRepair(beforeRawValue) {
            didChange = true
        }

        guard didChange else {
            return .init(outcome: .alreadyValid, url: url, beforeRawValue: beforeRawValue, afterRawValue: beforeRawValue)
        }

        resourceValues.quarantineProperties = quarantineProperties
        var mutableURL = url
        try mutableURL.setResourceValues(resourceValues)

        let afterRawValue = rawQuarantineAttribute(at: url)
        return .init(outcome: .repaired, url: url, beforeRawValue: beforeRawValue, afterRawValue: afterRawValue)
    }

    static func rawQuarantineAttribute(at url: URL) -> String? {
        url.path.withCString { pathPointer in
            quarantineAttributeName.withCString { attributePointer in
                let size = getxattr(pathPointer, attributePointer, nil, 0, 0, XATTR_NOFOLLOW)
                guard size >= 0 else { return nil }

                var buffer = [UInt8](repeating: 0, count: Int(size))
                let bytesRead = getxattr(pathPointer, attributePointer, &buffer, buffer.count, 0, XATTR_NOFOLLOW)
                guard bytesRead >= 0 else { return nil }

                return String(decoding: buffer.prefix(Int(bytesRead)), as: UTF8.self)
            }
        }
    }

    static func rawQuarantineNeedsLaunchServicesRepair(_ rawValue: String) -> Bool {
        let components = rawValue.split(separator: ";", omittingEmptySubsequences: false)
        guard components.count >= 4 else { return true }
        return components[3].isEmpty
    }

    private static func inferredQuarantineType(for dataURL: URL?) -> String {
        guard let scheme = dataURL?.scheme?.lowercased() else {
            return kLSQuarantineTypeOtherDownload as String
        }
        switch scheme {
        case "http", "https":
            return kLSQuarantineTypeWebDownload as String
        default:
            return kLSQuarantineTypeOtherDownload as String
        }
    }

    private static func newestItem(
        in rootURL: URL,
        fileManager: FileManager,
        skipPackageDescendants: Bool,
        matching predicate: (URL, URLResourceValues, FileManager.DirectoryEnumerator) -> Bool
    ) -> URL? {
        guard fileManager.fileExists(atPath: rootURL.path) else { return nil }

        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey, .isDirectoryKey]
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles],
            errorHandler: nil
        ) else {
            return nil
        }

        var newestURL: URL?
        var newestDate = Date.distantPast

        for case let candidateURL as URL in enumerator {
            let resourceValues = (try? candidateURL.resourceValues(forKeys: Set(keys))) ?? URLResourceValues()
            if skipPackageDescendants && (candidateURL.pathExtension == "app" || candidateURL.pathExtension == "pkg") {
                enumerator.skipDescendants()
            }
            guard predicate(candidateURL, resourceValues, enumerator) else { continue }

            let contentModificationDate = resourceValues.contentModificationDate ?? Date.distantPast
            if newestURL == nil || contentModificationDate > newestDate {
                newestURL = candidateURL
                newestDate = contentModificationDate
            }
        }

        return newestURL
    }
}
