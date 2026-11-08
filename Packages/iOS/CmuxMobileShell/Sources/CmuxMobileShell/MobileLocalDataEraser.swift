public import Foundation
internal import os
#if os(iOS)
import Security
import UIKit
import UserNotifications
import WebKit
#endif

/// Returns the app to the state of a fresh install by erasing everything cmux
/// stores on this device: keychain items, the app's `UserDefaults` domain, and
/// the app container's Documents, Library, and tmp contents.
///
/// It never contacts the cmux backend. Server-side state (the account, Cloud
/// VMs, other devices) is untouched; the caller runs the normal sign-out first
/// so push tokens and the Stack session are revoked the usual way.
///
/// Live objects built at the app root keep writing state after an in-process
/// erase (analytics on background, cached settings, open SQLite handles). The
/// erase therefore leaves a marker, and the next launch repeats the erase
/// through ``completePendingEraseIfNeeded()`` before the app root builds any of
/// those objects. The marker is removed only after that pass succeeds.
public struct MobileLocalDataEraser: Sendable {
    /// Deletes every keychain item the app can reach. Returns `false` when the
    /// keychain could not be erased (for example, locked before first unlock).
    public typealias KeychainEraser = @Sendable () -> Bool
    /// Clears state held by system services rather than files the app owns
    /// directly (web data, delivered notifications, remote registration).
    public typealias SystemStateEraser = @MainActor @Sendable () async -> Void

    /// Library children the app must not delete. `Preferences` is cleared
    /// through ``UserDefaults/removePersistentDomain(forName:)`` so `cfprefsd`
    /// stays coherent, and `SplashBoard` is the system's launch-screen cache.
    static let preservedLibraryEntries: Set<String> = ["Preferences", "SplashBoard"]
    static let pendingMarkerName = "cmux-pending-local-data-erase"

    private let homeDirectory: URL
    private let defaultsSuiteName: String?
    private let defaultsDomain: String
    private let eraseKeychain: KeychainEraser
    private let eraseSystemState: SystemStateEraser

    /// - Parameters:
    ///   - homeDirectory: The app container root holding Documents, Library, and tmp.
    ///   - defaultsSuiteName: `nil` for `UserDefaults.standard`; tests pass a suite.
    ///   - defaultsDomain: The persistent domain to remove, normally the bundle id.
    public init(
        homeDirectory: URL,
        defaultsSuiteName: String?,
        defaultsDomain: String,
        eraseKeychain: @escaping KeychainEraser,
        eraseSystemState: @escaping SystemStateEraser
    ) {
        self.homeDirectory = homeDirectory
        self.defaultsSuiteName = defaultsSuiteName
        self.defaultsDomain = defaultsDomain
        self.eraseKeychain = eraseKeychain
        self.eraseSystemState = eraseSystemState
    }

    var pendingMarkerURL: URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent(Self.pendingMarkerName, isDirectory: false)
    }

    /// Whether a previous erase still needs its launch pass.
    public var hasPendingErase: Bool {
        FileManager.default.fileExists(atPath: pendingMarkerURL.path)
    }

    /// Schedules the launch pass, then erases all local data now.
    ///
    /// Call after the normal sign-out finishes. The marker is written first
    /// and survives the in-process pass, so a process killed mid-erase still
    /// finishes on the next launch. Returns `false` when the marker could not
    /// be written or some item could not be removed; nothing is erased
    /// without a marker, so a failed call can simply be retried.
    @MainActor
    @discardableResult
    public func erase() async -> Bool {
        Self.log.notice("erasing all local data")
        guard writePendingMarker() else { return false }
        await eraseSystemState()
        // File and keychain work can be large; keep it off the main actor.
        let eraser = self
        return await Task.detached { eraser.eraseStoredData() }.value
    }

    /// Runs the launch pass of a pending erase. Call before the app root builds
    /// anything that reads keychain, defaults, or container files.
    ///
    /// - Returns: `true` when an erase was pending and completed.
    @discardableResult
    public func completePendingEraseIfNeeded() -> Bool {
        guard hasPendingErase else { return false }
        Self.log.notice("completing pending local data erase")
        guard eraseStoredData() else {
            // Keep the marker so the next launch retries the failed part.
            Self.log.error("pending local data erase incomplete; will retry next launch")
            return false
        }
        do {
            try FileManager.default.removeItem(at: pendingMarkerURL)
        } catch {
            Self.log.error("could not remove local data erase marker: \(error.localizedDescription, privacy: .public)")
            return false
        }
        return true
    }

    private func eraseStoredData() -> Bool {
        let didEraseKeychain = eraseKeychain()
        eraseDefaults()
        let didEraseFiles = eraseContainerFiles()
        return didEraseKeychain && didEraseFiles
    }

    private func eraseDefaults() {
        let defaults = defaultsSuiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        defaults.removePersistentDomain(forName: defaultsDomain)
    }

    private func eraseContainerFiles() -> Bool {
        let fileManager = FileManager.default
        var didEraseAll = true
        for (directory, preserved) in [
            ("Documents", Set<String>()),
            ("tmp", Set<String>()),
            ("Library", Self.preservedLibraryEntries.union([Self.pendingMarkerName])),
        ] {
            let url = homeDirectory.appendingPathComponent(directory, isDirectory: true)
            let children: [String]
            do {
                children = try fileManager.contentsOfDirectory(atPath: url.path)
            } catch CocoaError.fileReadNoSuchFile {
                continue
            } catch {
                didEraseAll = false
                continue
            }
            for child in children where !preserved.contains(child) {
                do {
                    try fileManager.removeItem(at: url.appendingPathComponent(child))
                } catch CocoaError.fileNoSuchFile {
                    continue
                } catch {
                    Self.log.error("could not erase \(directory, privacy: .public)/\(child, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    didEraseAll = false
                }
            }
        }
        return didEraseAll
    }

    private func writePendingMarker() -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: pendingMarkerURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data().write(to: pendingMarkerURL, options: .atomic)
            return true
        } catch {
            Self.log.error("could not write local data erase marker: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.cmuxterm.app",
        category: "local-data-erase"
    )
}

#if os(iOS)
public extension MobileLocalDataEraser {
    /// The eraser for this app's own container, defaults domain, and keychain.
    static func current() -> MobileLocalDataEraser {
        MobileLocalDataEraser(
            homeDirectory: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
            defaultsSuiteName: nil,
            defaultsDomain: Bundle.main.bundleIdentifier ?? "com.cmuxterm.app",
            eraseKeychain: eraseAllKeychainItems,
            eraseSystemState: eraseSystemServiceState
        )
    }

    /// Deletes every item of every class in every access group this app (and
    /// its notification extension, which shares the group) can reach, including
    /// device-only items that would otherwise survive an app reinstall.
    ///
    /// The query omits `kSecAttrSynchronizable`, so it matches only items local
    /// to this device. Deleting an iCloud-synchronized item would also delete
    /// it on the user's other devices.
    ///
    /// iOS only: on macOS the same query would reach the user's login keychain.
    private static func eraseAllKeychainItems() -> Bool {
        let classes = [
            kSecClassGenericPassword,
            kSecClassInternetPassword,
            kSecClassCertificate,
            kSecClassKey,
            kSecClassIdentity,
        ]
        var didEraseAll = true
        for itemClass in classes {
            let query: [String: Any] = [kSecClass as String: itemClass]
            let status = SecItemDelete(query as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound {
                log.error("keychain erase failed for class \(String(describing: itemClass), privacy: .public): \(status)")
                didEraseAll = false
            }
        }
        return didEraseAll
    }

    @MainActor
    private static func eraseSystemServiceState() async {
        await WKWebsiteDataStore.default().removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        )
        URLCache.shared.removeAllCachedResponses()
        HTTPCookieStorage.shared.removeCookies(since: .distantPast)
        let notifications = UNUserNotificationCenter.current()
        notifications.removeAllDeliveredNotifications()
        notifications.removeAllPendingNotificationRequests()
        try? await notifications.setBadgeCount(0)
        UIApplication.shared.unregisterForRemoteNotifications()
    }
}
#endif
