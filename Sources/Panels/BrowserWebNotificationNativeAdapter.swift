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
private typealias CopyWKStringFunction = @convention(c) (UnsafeRawPointer?) -> UnsafeRawPointer?
private typealias GetNotificationSecurityOriginFunction = @convention(c) (UnsafeRawPointer?) -> UnsafeRawPointer?
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

    private struct ManagerState {
        let pointer: UnsafeRawPointer
        var pageKeys: Set<UInt> = []
    }

    private let setProvider: SetProviderFunction?
    private let didShow: DidShowFunction?
    private let notificationID: GetNotificationIDFunction?
    private let notificationIsPersistent: GetNotificationBooleanFunction?
    private let copyTitle: CopyWKStringFunction?
    private let copyBody: CopyWKStringFunction?
    private let notificationSecurityOrigin: GetNotificationSecurityOriginFunction?
    private let copySecurityOriginString: CopyWKStringFunction?
    private let stringMaximumSize: StringMaximumSizeFunction?
    private let stringGetUTF8: StringGetUTF8Function?
    private let release: ReleaseFunction?
    private let dataStoreDelegate = BrowserWebsiteDataStoreNotificationDelegate()

    private var registrations: [UInt: Registration] = [:]
    private var pageManagers: [UInt: UnsafeRawPointer] = [:]
    private var dataStoreProfiles: [ObjectIdentifier: UUID] = [:]
    private var managers: [UInt: ManagerState] = [:]
    private var persistentClicks: [UUID: PersistentClickRegistration] = [:]
#if DEBUG
    var forceForegroundFallbackForTesting = false
    var externalURLOpenerForTesting: ((URL) -> Bool)?
    var persistentClickProcessorForTesting: ((WKWebsiteDataStore, NSDictionary, @escaping (Bool) -> Void) -> Bool)?
    var didShowObserverForTesting: ((UnsafeRawPointer, UInt64) -> Void)?
#endif

    private init() {
        setProvider = Self.symbol("WKNotificationManagerSetProvider")
        didShow = Self.symbol("WKNotificationManagerProviderDidShowNotification")
        notificationID = Self.symbol("WKNotificationGetID")
        notificationIsPersistent = Self.symbol("WKNotificationGetIsPersistent")
        copyTitle = Self.symbol("WKNotificationCopyTitle")
        copyBody = Self.symbol("WKNotificationCopyBody")
        notificationSecurityOrigin = Self.symbol("WKNotificationGetSecurityOrigin")
        copySecurityOriginString = Self.symbol("WKSecurityOriginCopyToString")
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
        guard BrowserWebNotificationSettings.isForwardingEnabled else { return }
        compactDeadRegistrations()
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
        let pageKey = Self.key(page)
        removeRegistration(forPageKey: pageKey)
        pageManagers[pageKey] = manager
        registrations[pageKey] = Registration(
            webView: webView,
            panel: panel,
            profileID: profileID,
            manager: manager
        )
        let shouldInstallProvider = provisionManager(manager, pageKey: pageKey)
        if shouldInstallProvider { installProvider(on: manager) }
    }

    func unregister(webView: WKWebView) {
        if let page = Self.objectPointer(from: webView, selector: "_pageForTesting") {
            removeRegistration(forPageKey: Self.key(page))
        } else if let pageKey = registrations.first(where: { $0.value.webView === webView })?.key {
            removeRegistration(forPageKey: pageKey)
        }
    }

    func notificationPermissions(for dataStore: WKWebsiteDataStore) -> [String: NSNumber] {
        guard BrowserWebNotificationSettings.isForwardingEnabled,
              let profileID = dataStoreProfiles[ObjectIdentifier(dataStore)] else { return [:] }
        let origins = BrowserProfileStore.shared.notificationPermissions.origins(for: profileID)
        var result: [String: NSNumber] = [:]
        for origin in origins.allowed { result[origin] = true }
        for origin in origins.denied { result[origin] = false }
        return result
    }

    func showPersistentNotification(_ notification: NSObject, from dataStore: WKWebsiteDataStore) {
        guard BrowserWebNotificationSettings.isForwardingEnabled,
              dataStoreProfiles[ObjectIdentifier(dataStore)] != nil,
              let title = Self.stringProperty("title", on: notification),
              let originString = Self.stringProperty("origin", on: notification),
              let origin = URL(string: originString) else {
            return
        }
        let body = Self.stringProperty("body", on: notification) ?? ""
        let displayOrigin = Self.displayOrigin(for: origin)
        let notificationID = deliverGlobal(title: title, body: body, displayOrigin: displayOrigin)
        if let dictionary = Self.dictionaryProperty("dictionaryRepresentation", on: notification) {
            persistentClicks[notificationID] = PersistentClickRegistration(
                dataStore: dataStore,
                dictionary: dictionary,
                origin: displayOrigin
            )
        }
    }

    /// Runs a service worker's notification-click action when its in-memory
    /// registration is still live, otherwise opens the logical origin.
    @discardableResult
    func handleGlobalNotificationClick(notificationID: UUID, fallbackOrigin: URL) -> Bool {
        let displayFallbackOrigin = Self.displayOrigin(for: fallbackOrigin)
        guard let registration = persistentClicks.removeValue(forKey: notificationID),
              let dataStore = registration.dataStore,
              processPersistentClick(
                  on: dataStore,
                  dictionary: registration.dictionary,
                  completion: { processed in
                      if !processed { _ = self.openExternalURL(registration.origin) }
                  }
              ) else {
            return openExternalURL(displayFallbackOrigin)
        }
        return true
    }

    func removePersistentClickRegistrations(notificationIDs: [UUID]) {
        for notificationID in notificationIDs {
            persistentClicks.removeValue(forKey: notificationID)
        }
    }

#if DEBUG
    func setProfileForTesting(_ profileID: UUID?, on dataStore: WKWebsiteDataStore) {
        let key = ObjectIdentifier(dataStore)
        if let profileID { dataStoreProfiles[key] = profileID }
        else { dataStoreProfiles.removeValue(forKey: key) }
    }

    @discardableResult
    func provisionManagerForTesting(_ manager: UnsafeRawPointer) -> Bool {
        provisionManager(manager, pageKey: nil)
    }

    func simulateManagerRemovalForTesting(_ manager: UnsafeRawPointer) {
        notificationManagerWasRemoved(manager)
    }

    func isManagerTrackedForTesting(_ manager: UnsafeRawPointer) -> Bool {
        managers[Self.key(manager)] != nil
    }

    func trackPageManagerForTesting(pageKey: UInt, manager: UnsafeRawPointer) {
        pageManagers[pageKey] = manager
        _ = provisionManager(manager, pageKey: pageKey)
    }

    func simulatePageRegistrationTeardownForTesting(pageKey: UInt) {
        removeRegistration(forPageKey: pageKey)
    }

    func acknowledgeForegroundNotificationForTesting(pageKey: UInt, notificationID: UInt64) {
        guard let manager = pageManagers[pageKey] else { return }
        acknowledgeNotificationShown(manager: manager, notificationID: notificationID)
    }

    func hasPersistentClickRegistrationForTesting(_ notificationID: UUID) -> Bool {
        persistentClicks[notificationID] != nil
    }

    func registerPersistentClickForTesting(
        notificationID: UUID,
        dataStore: WKWebsiteDataStore,
        dictionary: NSDictionary = [:],
        origin: URL
    ) {
        persistentClicks[notificationID] = PersistentClickRegistration(
            dataStore: dataStore,
            dictionary: dictionary,
            origin: Self.displayOrigin(for: origin)
        )
    }

    func resetNativeDeliveryTestingState() {
        externalURLOpenerForTesting = nil
        persistentClickProcessorForTesting = nil
        didShowObserverForTesting = nil
        persistentClicks.removeAll()
    }
#endif

    private func installDataStoreDelegate(on dataStore: WKWebsiteDataStore) {
        let selector = NSSelectorFromString("set_delegate:")
        guard dataStore.responds(to: selector) else { return }
        dataStore.perform(selector, with: dataStoreDelegate)
    }

    private func installProvider(on manager: UnsafeRawPointer) {
        guard let setProvider else { return }
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
            addNotificationManager: { manager, clientInfo in
                guard let manager, let clientInfo else { return }
                let adapter = Unmanaged<BrowserWebNotificationNativeAdapter>
                    .fromOpaque(clientInfo)
                    .takeUnretainedValue()
                MainActor.assumeIsolated {
                    adapter.notificationManagerWasAdded(manager)
                }
            },
            removeNotificationManager: { manager, clientInfo in
                guard let manager, let clientInfo else { return }
                let adapter = Unmanaged<BrowserWebNotificationNativeAdapter>
                    .fromOpaque(clientInfo)
                    .takeUnretainedValue()
                MainActor.assumeIsolated {
                    adapter.notificationManagerWasRemoved(manager)
                }
            },
            notificationPermissions: { _ in nil },
            clearNotifications: nil
        )
        withUnsafePointer(to: &provider.base) { setProvider(manager, UnsafeRawPointer($0)) }
    }

    private func show(page: UnsafeRawPointer?, notification: UnsafeRawPointer?) {
        guard let notification,
              let title = copiedString(using: copyTitle, from: notification) else {
            return
        }
        let body = copiedString(using: copyBody, from: notification) ?? ""
        let id = notificationID?(notification) ?? 0
        let persistent = notificationIsPersistent?(notification) ?? false
        let securityOrigin = notificationSecurityOrigin?(notification)
            .flatMap { copiedString(using: copySecurityOriginString, from: $0) }
            .flatMap(URL.init(string:))

        if let page {
            let pageKey = Self.key(page)
            registrations[pageKey]?.panel?.handleNativeWebNotification(
                title: title,
                body: body,
                securityOrigin: securityOrigin
            )
            if !persistent, id != 0, let manager = pageManagers[pageKey] {
                acknowledgeNotificationShown(manager: manager, notificationID: id)
            }
        } else if persistent {
            // Persistent/service-worker notifications are delivered through
            // the website-data-store delegate, which preserves profile and
            // origin metadata needed for the global target and click action.
            return
        }
    }

    private func acknowledgeNotificationShown(manager: UnsafeRawPointer, notificationID: UInt64) {
#if DEBUG
        if let didShowObserverForTesting {
            didShowObserverForTesting(manager, notificationID)
            return
        }
#endif
        didShow?(manager, notificationID)
    }

    @discardableResult
    private func deliverGlobal(title: String, body: String, displayOrigin: URL) -> UUID {
        TerminalNotificationStore.shared.addGlobalWebsiteNotification(
            title: title,
            subtitle: displayOrigin.host ?? "",
            body: body,
            origin: displayOrigin
        )
    }

    private func copiedString(
        using copy: CopyWKStringFunction?,
        from object: UnsafeRawPointer
    ) -> String? {
        guard let stringRef = copy?(object) else { return nil }
        defer { release?(stringRef) }
        guard let stringMaximumSize, let stringGetUTF8 else { return nil }
        let capacity = stringMaximumSize(stringRef)
        guard capacity > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: capacity)
        guard stringGetUTF8(stringRef, &buffer, capacity) > 0 else { return nil }
        return String(cString: buffer)
    }

    private func provisionManager(_ manager: UnsafeRawPointer, pageKey: UInt?) -> Bool {
        let managerKey = Self.key(manager)
        let wasNew = managers[managerKey] == nil
        if wasNew { managers[managerKey] = ManagerState(pointer: manager) }
        if let pageKey { managers[managerKey]?.pageKeys.insert(pageKey) }
        return wasNew
    }

    private func notificationManagerWasAdded(_ manager: UnsafeRawPointer) {
        _ = provisionManager(manager, pageKey: nil)
    }

    private func notificationManagerWasRemoved(_ manager: UnsafeRawPointer) {
        let managerKey = Self.key(manager)
        let pageKeys = managers.removeValue(forKey: managerKey)?.pageKeys ?? []
        for pageKey in pageKeys { registrations.removeValue(forKey: pageKey) }
        // Defensive cleanup covers registrations created before WebKit invoked
        // addNotificationManager, as well as any weak-registration drift.
        registrations = registrations.filter { Self.key($0.value.manager) != managerKey }
        pageManagers = pageManagers.filter { Self.key($0.value) != managerKey }
    }

    private func removeRegistration(forPageKey pageKey: UInt) {
        guard let registration = registrations.removeValue(forKey: pageKey) else { return }
        managers[Self.key(registration.manager)]?.pageKeys.remove(pageKey)
    }

    private func compactDeadRegistrations() {
        let deadPageKeys = registrations.compactMap { pageKey, registration in
            registration.webView == nil || registration.panel == nil ? pageKey : nil
        }
        for pageKey in deadPageKeys { removeRegistration(forPageKey: pageKey) }
    }

    private static func displayOrigin(for origin: URL) -> URL {
        BrowserPanel.remoteProxyDisplayURL(for: origin) ?? origin
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

    private func processPersistentClick(
        on dataStore: WKWebsiteDataStore,
        dictionary: NSDictionary,
        completion: @escaping (Bool) -> Void
    ) -> Bool {
#if DEBUG
        if let persistentClickProcessorForTesting {
            return persistentClickProcessorForTesting(dataStore, dictionary, completion)
        }
#endif
        return Self.processPersistentClick(on: dataStore, dictionary: dictionary, completion: completion)
    }

    @discardableResult
    private func openExternalURL(_ url: URL) -> Bool {
#if DEBUG
        if let externalURLOpenerForTesting { return externalURLOpenerForTesting(url) }
#endif
        return NSWorkspace.shared.open(url)
    }

    private static func key(_ pointer: UnsafeRawPointer) -> UInt {
        UInt(bitPattern: pointer)
    }

    private static func symbol<T>(_ name: String) -> T? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
        return unsafeBitCast(symbol, to: T.self)
    }
}
