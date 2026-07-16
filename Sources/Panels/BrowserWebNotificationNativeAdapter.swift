import AppKit
import CmuxBrowser
import CmuxSettings
import Darwin
import Foundation
import ObjectiveC
import WebKit

private typealias WKNotificationShowCallback = @convention(c) (
    UnsafeRawPointer?, UnsafeRawPointer?, UnsafeRawPointer?
) -> Void
private typealias WKNotificationCallback = @convention(c) (UnsafeRawPointer?, UnsafeRawPointer?) -> Void
private typealias WKNotificationManagerCallback = @convention(c) (UnsafeRawPointer?, UnsafeRawPointer?) -> Void
private typealias WKNotificationPermissionsCallback = @convention(c) (UnsafeRawPointer?) -> UnsafeRawPointer?
private typealias WKNotificationClearCallback = @convention(c) (UnsafeRawPointer?, UnsafeRawPointer?) -> Void

private struct WKNotificationProviderBaseRuntime {
    var version: Int32
    var clientInfo: UnsafeRawPointer?
}

private struct WKNotificationProviderV0Runtime {
    var base: WKNotificationProviderBaseRuntime
    var show: WKNotificationShowCallback?
    var cancel: WKNotificationCallback?
    var didDestroyNotification: WKNotificationCallback?
    var addNotificationManager: WKNotificationManagerCallback?
    var removeNotificationManager: WKNotificationManagerCallback?
    var notificationPermissions: WKNotificationPermissionsCallback?
    var clearNotifications: WKNotificationClearCallback?
}

private typealias SetProviderFunction = @convention(c) (
    UnsafeRawPointer?, UnsafeRawPointer?
) -> Void
private typealias DidShowFunction = @convention(c) (UnsafeRawPointer?, UInt64) -> Void
private typealias GetNotificationIDFunction = @convention(c) (UnsafeRawPointer?) -> UInt64
private typealias GetNotificationBooleanFunction = @convention(c) (UnsafeRawPointer?) -> Bool
private typealias CopyNotificationStringFunction = @convention(c) (UnsafeRawPointer?) -> UnsafeRawPointer?
private typealias StringMaximumSizeFunction = @convention(c) (UnsafeRawPointer?) -> Int
private typealias StringGetUTF8Function = @convention(c) (UnsafeRawPointer?, UnsafeMutablePointer<CChar>?, Int) -> Int
private typealias ReleaseFunction = @convention(c) (UnsafeRawPointer?) -> Void
@MainActor
private final class BrowserWebsiteDataStoreNotificationDelegate: NSObject {
    weak var adapter: BrowserWebNotificationNativeAdapter?

    @objc(notificationPermissionsForWebsiteDataStore:)
    func notificationPermissions(for dataStore: WKWebsiteDataStore) -> [String: NSNumber] {
        adapter?.notificationPermissions(for: dataStore) ?? [:]
    }

    @objc(websiteDataStore:showNotification:)
    func websiteDataStore(_ dataStore: WKWebsiteDataStore, showNotification notification: NSObject) {
        adapter?.showPersistentNotification(notification, from: dataStore)
    }
}

/// Runtime-only bridge to WebKit's notification provider SPI.
///
/// Every symbol and selector is probed before use. Unsupported runtimes leave
/// foreground delivery to the compatibility script and background delivery off.
@MainActor
final class BrowserWebNotificationNativeAdapter {
    static let shared = BrowserWebNotificationNativeAdapter()

    private struct Registration {
        weak var webView: WKWebView?
        weak var panel: BrowserPanel?
        let profileID: UUID
        let manager: UnsafeRawPointer
    }

    private struct PersistentClickRegistration {
        weak var dataStore: WKWebsiteDataStore?
        let dictionary: NSDictionary
        let origin: URL
    }

    private let setProvider: SetProviderFunction?
    private let didShow: DidShowFunction?
    private let notificationID: GetNotificationIDFunction?
    private let notificationIsPersistent: GetNotificationBooleanFunction?
    private let copyTitle: CopyNotificationStringFunction?
    private let copyBody: CopyNotificationStringFunction?
    private let stringMaximumSize: StringMaximumSizeFunction?
    private let stringGetUTF8: StringGetUTF8Function?
    private let release: ReleaseFunction?
    private let dataStoreDelegate = BrowserWebsiteDataStoreNotificationDelegate()

    private var registrations: [UInt: Registration] = [:]
    private var dataStoreProfiles: [ObjectIdentifier: UUID] = [:]
    private var managers: Set<UInt> = []
    private var persistentClicks: [UUID: PersistentClickRegistration] = [:]
#if DEBUG
    var forceForegroundFallbackForTesting = false
#endif

    private init() {
        setProvider = Self.symbol("WKNotificationManagerSetProvider")
        didShow = Self.symbol("WKNotificationManagerProviderDidShowNotification")
        notificationID = Self.symbol("WKNotificationGetID")
        notificationIsPersistent = Self.symbol("WKNotificationGetIsPersistent")
        copyTitle = Self.symbol("WKNotificationCopyTitle")
        copyBody = Self.symbol("WKNotificationCopyBody")
        stringMaximumSize = Self.symbol("WKStringGetMaximumUTF8CStringSize")
        stringGetUTF8 = Self.symbol("WKStringGetUTF8CString")
        release = Self.symbol("WKRelease")
        dataStoreDelegate.adapter = self
    }

    /// Whether the page shim must be installed for foreground notifications.
    var shouldInstallForegroundFallback: Bool {
#if DEBUG
        if forceForegroundFallbackForTesting { return true }
#endif
        // The native provider has not yet been empirically qualified on macOS 14.
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion <= 14 { return true }
        return !nativeSymbolsAvailable
            || !WKProcessPool.self.instancesRespond(to: NSSelectorFromString("_notificationManagerForTesting"))
    }

    /// Whether background/service-worker callbacks are available independently.
    var backgroundNotificationsAvailable: Bool {
        WKWebsiteDataStore.self.instancesRespond(to: NSSelectorFromString("set_delegate:"))
            && WKWebsiteDataStore.self.instancesRespond(
                to: NSSelectorFromString("_processPersistentNotificationClick:completionHandler:")
            )
    }

    private var nativeSymbolsAvailable: Bool {
        setProvider != nil && didShow != nil && notificationID != nil && copyTitle != nil
            && copyBody != nil && stringMaximumSize != nil && stringGetUTF8 != nil && release != nil
    }

    func register(webView: WKWebView, profileID: UUID, panel: BrowserPanel) {
        guard SettingCatalog().browser.forwardWebNotifications.value(in: .standard) else { return }
        dataStoreProfiles[ObjectIdentifier(webView.configuration.websiteDataStore)] = profileID
        installDataStoreDelegate(on: webView.configuration.websiteDataStore)

        guard nativeSymbolsAvailable,
              let page = Self.objectPointer(from: webView, selector: "_pageForTesting"),
              let manager = Self.objectPointer(
                  from: webView.configuration.processPool,
                  selector: "_notificationManagerForTesting"
              ) else {
            return
        }
        registrations[Self.key(page)] = Registration(
            webView: webView,
            panel: panel,
            profileID: profileID,
            manager: manager
        )
        installProvider(on: manager)
    }

    func unregister(webView: WKWebView) {
        guard let page = Self.objectPointer(from: webView, selector: "_pageForTesting") else { return }
        registrations.removeValue(forKey: Self.key(page))
    }

    func notificationPermissions(for dataStore: WKWebsiteDataStore) -> [String: NSNumber] {
        guard let profileID = dataStoreProfiles[ObjectIdentifier(dataStore)] else { return [:] }
        let repository = BrowserProfileStore.shared.notificationPermissions
        var result: [String: NSNumber] = [:]
        for origin in repository.allowedOrigins(for: profileID) { result[origin] = true }
        for origin in repository.deniedOrigins(for: profileID) { result[origin] = false }
        return result
    }

    func showPersistentNotification(_ notification: NSObject, from dataStore: WKWebsiteDataStore) {
        guard let profileID = dataStoreProfiles[ObjectIdentifier(dataStore)],
              let title = Self.stringProperty("title", on: notification),
              let originString = Self.stringProperty("origin", on: notification),
              let origin = URL(string: originString) else {
            return
        }
        let body = Self.stringProperty("body", on: notification) ?? ""
        let notificationID = deliverGlobal(title: title, body: body, origin: origin, profileID: profileID)
        if let dictionary = Self.dictionaryProperty("dictionaryRepresentation", on: notification) {
            persistentClicks[notificationID] = PersistentClickRegistration(
                dataStore: dataStore,
                dictionary: dictionary,
                origin: origin
            )
        }
    }

    /// Runs a service worker's notification-click action when its in-memory
    /// registration is still live, otherwise opens the logical origin.
    func handleGlobalNotificationClick(notificationID: UUID, fallbackOrigin: URL) {
        guard let registration = persistentClicks.removeValue(forKey: notificationID),
              let dataStore = registration.dataStore,
              Self.processPersistentClick(
                  on: dataStore,
                  dictionary: registration.dictionary,
                  completion: { processed in
                      if !processed { NSWorkspace.shared.open(registration.origin) }
                  }
              ) else {
            NSWorkspace.shared.open(fallbackOrigin)
            return
        }
    }

    private func installDataStoreDelegate(on dataStore: WKWebsiteDataStore) {
        let selector = NSSelectorFromString("set_delegate:")
        guard dataStore.responds(to: selector) else { return }
        dataStore.perform(selector, with: dataStoreDelegate)
    }

    private func installProvider(on manager: UnsafeRawPointer) {
        let key = Self.key(manager)
        guard managers.insert(key).inserted, let setProvider else { return }
        let clientInfo = Unmanaged.passUnretained(self).toOpaque()
        var provider = WKNotificationProviderV0Runtime(
            base: WKNotificationProviderBaseRuntime(version: 0, clientInfo: clientInfo),
            show: { page, notification, clientInfo in
                guard let clientInfo else { return }
                let adapter = Unmanaged<BrowserWebNotificationNativeAdapter>
                    .fromOpaque(clientInfo)
                    .takeUnretainedValue()
                MainActor.assumeIsolated {
                    adapter.show(page: page, notification: notification)
                }
            },
            cancel: nil,
            didDestroyNotification: nil,
            addNotificationManager: nil,
            removeNotificationManager: nil,
            notificationPermissions: { _ in nil },
            clearNotifications: nil
        )
        withUnsafePointer(to: &provider.base) { setProvider(manager, UnsafeRawPointer($0)) }
    }

    private func show(page: UnsafeRawPointer?, notification: UnsafeRawPointer?) {
        guard let notification,
              let title = copiedString(using: copyTitle, notification: notification) else {
            return
        }
        let body = copiedString(using: copyBody, notification: notification) ?? ""
        let id = notificationID?(notification) ?? 0
        let persistent = notificationIsPersistent?(notification) ?? false

        if let page, let registration = registrations[Self.key(page)], let panel = registration.panel {
            panel.handleNativeWebNotification(title: title, body: body)
            if id != 0, let didShow {
                didShow(registration.manager, id)
            }
        } else if persistent {
            // Persistent/service-worker notifications are delivered through
            // the website-data-store delegate, which preserves profile and
            // origin metadata needed for the global target and click action.
            return
        }
    }

    @discardableResult
    private func deliverGlobal(title: String, body: String, origin: URL, profileID: UUID) -> UUID {
        let displayOrigin = BrowserPanel.remoteProxyDisplayURL(for: origin) ?? origin
        return TerminalNotificationStore.shared.addGlobalWebsiteNotification(
            title: title,
            subtitle: displayOrigin.host ?? origin.host ?? "",
            body: body,
            profileID: profileID,
            origin: displayOrigin
        )
    }

    private func copiedString(
        using copy: CopyNotificationStringFunction?,
        notification: UnsafeRawPointer
    ) -> String? {
        guard let stringRef = copy?(notification),
              let stringMaximumSize,
              let stringGetUTF8 else {
            return nil
        }
        defer { release?(stringRef) }
        let capacity = stringMaximumSize(stringRef)
        guard capacity > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: capacity)
        guard stringGetUTF8(stringRef, &buffer, capacity) > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func objectPointer(from object: NSObject, selector name: String) -> UnsafeRawPointer? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector),
              let method = class_getInstanceMethod(type(of: object), selector) else {
            return nil
        }
        typealias Function = @convention(c) (AnyObject, Selector) -> UnsafeRawPointer?
        let function = unsafeBitCast(method_getImplementation(method), to: Function.self)
        return function(object, selector)
    }

    private static func stringProperty(_ name: String, on object: NSObject) -> String? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? String
    }

    private static func dictionaryProperty(_ name: String, on object: NSObject) -> NSDictionary? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? NSDictionary
    }

    private static func processPersistentClick(
        on dataStore: WKWebsiteDataStore,
        dictionary: NSDictionary,
        completion: @escaping (Bool) -> Void
    ) -> Bool {
        let selector = NSSelectorFromString("_processPersistentNotificationClick:completionHandler:")
        guard dataStore.responds(to: selector),
              let method = class_getInstanceMethod(type(of: dataStore), selector) else {
            return false
        }
        typealias Function = @convention(c) (
            AnyObject, Selector, NSDictionary, @escaping @convention(block) (Bool) -> Void
        ) -> Void
        let implementation = method_getImplementation(method)
        let function = unsafeBitCast(implementation, to: Function.self)
        function(dataStore, selector, dictionary, completion)
        return true
    }

    private static func key(_ pointer: UnsafeRawPointer) -> UInt {
        UInt(bitPattern: pointer)
    }

    private static func symbol<T>(_ name: String) -> T? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
        return unsafeBitCast(symbol, to: T.self)
    }
}
