import Darwin
import Foundation

struct SparkleUpdatePreflight {
    let hostBundle: Bundle
    let fileManager: FileManager
    let log: any UpdateLogging

    func run() {
        removeQuarantineFromSparkleFramework()
        prepareInstallationCacheForSparkle()
    }

    private func removeQuarantineFromSparkleFramework() {
        let frameworkURL = hostBundle.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Frameworks", isDirectory: true)
            .appendingPathComponent("Sparkle.framework", isDirectory: true)
        guard fileManager.fileExists(atPath: frameworkURL.path) else { return }

        var removedCount = removeQuarantineAttribute(at: frameworkURL) ? 1 : 0
        guard let enumerator = fileManager.enumerator(
            at: frameworkURL,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            log.append("Failed enumerating Sparkle.framework for quarantine cleanup")
            return
        }

        for case let url as URL in enumerator {
            if removeQuarantineAttribute(at: url) {
                removedCount += 1
            }
        }

        if removedCount > 0 {
            log.append("Removed Sparkle quarantine attributes from \(removedCount) bundled helper item(s)")
        }
    }

    private func removeQuarantineAttribute(at url: URL) -> Bool {
        let result = removexattr(url.path, "com.apple.quarantine", 0)
        if result == 0 {
            return true
        }
        if errno != ENOATTR {
            log.append("Failed removing Sparkle quarantine attribute at \(url.path): errno \(errno)")
        }
        return false
    }

    private func prepareInstallationCacheForSparkle() {
        guard let bundleIdentifier = hostBundle.bundleIdentifier else { return }
        guard let cachesURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }

        let installationURL = cachesURL
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("org.sparkle-project.Sparkle", isDirectory: true)
            .appendingPathComponent("Installation", isDirectory: true)

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: installationURL.path, isDirectory: &isDirectory) else {
            return
        }

        if !isDirectory.boolValue {
            removeInstallationCache(at: installationURL, reason: "file")
            return
        }

        guard let contents = try? fileManager.contentsOfDirectory(atPath: installationURL.path) else {
            log.append("Failed reading Sparkle installation cache at \(installationURL.path)")
            return
        }
        guard contents.isEmpty else { return }

        removeInstallationCache(at: installationURL, reason: "empty directory")
    }

    private func removeInstallationCache(at url: URL, reason: String) {
        do {
            try fileManager.removeItem(at: url)
            log.append("Removed Sparkle installation cache \(reason) at \(url.path)")
        } catch {
            log.append("Failed removing Sparkle installation cache \(reason): \(error)")
        }
    }
}
