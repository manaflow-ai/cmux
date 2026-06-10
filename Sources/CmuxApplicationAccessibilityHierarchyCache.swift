import AppKit
import CmuxAuthRuntime
import CmuxControlSocket
import CmuxSettings
import CmuxSettingsUI
import CmuxSocketControl
import CmuxUpdater
import CmuxUpdaterUI
import SwiftUI
import Bonsplit
import CMUXWorkstream
import CoreServices
import UserNotifications
import Sentry
import WebKit
import Combine
import ObjectiveC.runtime
import Darwin
import CmuxFoundation


// MARK: - CmuxApplicationAccessibilityHierarchyCache
/// Caches `AXWindows` responses so repeated AX polls can reuse the same
/// snapshot while the app window graph is unchanged. Only `.windows` is
/// cached; `.children` and `.visibleChildren` fall through to AppKit so the
/// menu bar stays present in the accessibility tree for VoiceOver and other
/// AX clients. `.mainWindow` / `.focusedWindow` also fall through, so AppKit
/// remains authoritative on focus transitions.
final class CmuxApplicationAccessibilityHierarchyCache {
    enum Resolution {
        case passthrough
        case handled(Any?)
    }

    struct WindowToken: Equatable {
        let identity: ObjectIdentifier
        let windowNumber: Int
        let isVisible: Bool
        let isMiniaturized: Bool
    }

    struct StateToken: Equatable {
        let windows: [WindowToken]

        init(windows: [NSWindow]) {
            self.windows = windows.map {
                WindowToken(
                    identity: ObjectIdentifier($0),
                    windowNumber: $0.windowNumber,
                    isVisible: $0.isVisible,
                    isMiniaturized: $0.isMiniaturized
                )
            }
        }
    }

    struct Snapshot {
        let windows: [NSWindow]
    }

    static let shared = CmuxApplicationAccessibilityHierarchyCache()

    let notificationCenter: NotificationCenter
    private var cachedStateToken: StateToken?
    private var cachedSnapshot: Snapshot?
    private var windowCloseObserver: NSObjectProtocol?

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
        // Drop strong refs to any window the instant it closes so the cache
        // never keeps a closed NSWindow alive between AX polls.
        windowCloseObserver = notificationCenter.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.invalidate()
        }
    }

    deinit {
        if let windowCloseObserver {
            notificationCenter.removeObserver(windowCloseObserver)
        }
    }

    func invalidate() {
        cachedStateToken = nil
        cachedSnapshot = nil
    }

    func resolve(attribute: NSAccessibility.Attribute, application: NSApplication) -> Resolution {
        guard Self.supportsCaching(attribute) else { return .passthrough }
        let windows = application.windows
        let stateToken = StateToken(windows: windows)
        let value = value(for: attribute, stateToken: stateToken) {
            Snapshot(windows: windows)
        }
        return .handled(value)
    }

    func value(
        for attribute: NSAccessibility.Attribute,
        stateToken: StateToken,
        builder: () -> Snapshot
    ) -> Any? {
        guard Self.supportsCaching(attribute) else { return nil }

        let snapshot: Snapshot
        if cachedStateToken == stateToken, let cachedSnapshot {
            snapshot = cachedSnapshot
        } else {
            snapshot = builder()
            cachedStateToken = stateToken
            cachedSnapshot = snapshot
        }

        switch attribute.rawValue {
        case NSAccessibility.Attribute.windows.rawValue:
            return snapshot.windows
        default:
            return nil
        }
    }

    private static func supportsCaching(_ attribute: NSAccessibility.Attribute) -> Bool {
        attribute.rawValue == NSAccessibility.Attribute.windows.rawValue
    }
}

