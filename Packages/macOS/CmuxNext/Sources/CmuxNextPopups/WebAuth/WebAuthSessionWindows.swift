package import AppKit
package import CmuxNextBrowser
package import CmuxNextDesign
import Foundation
package import os

/// Opens each sign-in in its own window with a Chromium page, the same
/// window a page's sign-in popup uses (title, read-only location bar,
/// traffic lights), where Escape cancels. It is not a daemon tab: nothing records, restores or lists it.
/// A normal session uses the default browser profile, so a person already
/// signed in stays signed in; an ephemeral one gets an off-the-record
/// profile that ends with the panel.
@MainActor
package final class WebAuthSessionWindows: WebAuthSessionOpening {
    /// The app's services (the host). A strong reference makes no cycle:
    /// AppDelegate owns the handler, the broker and this opener, and the
    /// host holds none of them.
    private let host: any WebAuthHost
    private let logger: Logger
    private let profiles: OffTheRecordProfiles
    private let signInCallbacks: CEFSignInCallbacks
    private let contextMenus: BrowserContextMenuBuilder
    private let activeLook: ActiveLookScope?
    private let present: @MainActor (NSWindow, WindowActivation.Intent) -> Void
    private(set) var windows: [UUID: WebAuthSessionWindow] = [:]

    /// - Parameters:
    ///   - host: The app's services: the Chromium page and links out.
    ///   - logger: Where sign-in events log; each call site sets its own privacy.
    ///   - profiles: Where an ephemeral sign-in begins and ends its off-the-record profile.
    ///     Must be the instance the Chromium engine releases ended profiles from.
    ///   - signInCallbacks: Where a Chromium sign-in page registers the callback the shim stops.
    ///     Must be the instance the Chromium engine reports stopped callbacks to.
    ///   - contextMenus: The builder for a sign-in page's right-click menu.
    ///   - activeLook: The app's ``ActiveLookScope``, for each sign-in panel's backdrop.
    ///   - present: Orders a sign-in panel in (always with `.focus`). The default is
    ///     ``WindowActivation/show(_:_:)``, the app's one owner of window order and
    ///     activation; a test passes a recorder so it neither orders a window in nor
    ///     activates the test process.
    package init(
        host: any WebAuthHost,
        logger: Logger,
        profiles: OffTheRecordProfiles,
        signInCallbacks: CEFSignInCallbacks,
        contextMenus: BrowserContextMenuBuilder,
        activeLook: ActiveLookScope?,
        present: @escaping @MainActor (NSWindow, WindowActivation.Intent) -> Void = { WindowActivation.show($0, $1) }
    ) {
        self.host = host
        self.logger = logger
        self.profiles = profiles
        self.signInCallbacks = signInCallbacks
        self.contextMenus = contextMenus
        self.activeLook = activeLook
        self.present = present
    }

    package func open(_ request: any WebAuthSessionRequest, broker: WebAuthSessionBroker) -> (any WebAuthSessionSurface)? {
        let window = WebAuthSessionWindow(
            request: request, broker: broker, host: host, logger: logger,
            profiles: profiles, signInCallbacks: signInCallbacks, contextMenus: contextMenus, activeLook: activeLook,
            present: present
        ) { [weak self] id in
            self?.windows[id] = nil
        }
        windows[request.id] = window
        window.start()
        return window
    }
}
