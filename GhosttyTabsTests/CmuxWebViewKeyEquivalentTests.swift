import XCTest
import AppKit
import WebKit

#if canImport(cmuxterm_DEV)
@testable import cmuxterm_DEV
#elseif canImport(cmuxterm)
@testable import cmuxterm
#endif

final class CmuxWebViewKeyEquivalentTests: XCTestCase {
    private final class ActionSpy: NSObject {
        private(set) var invoked: Bool = false

        @objc func didInvoke(_ sender: Any?) {
            invoked = true
        }
    }

    func testCmdNRoutesToMainMenuWhenWebViewIsFirstResponder() {
        let spy = ActionSpy()
        installMenu(spy: spy, key: "n", modifiers: [.command])

        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let event = makeKeyDownEvent(key: "n", modifiers: [.command], keyCode: 45) // kVK_ANSI_N
        XCTAssertNotNil(event)

        XCTAssertTrue(webView.performKeyEquivalent(with: event!))
        XCTAssertTrue(spy.invoked)
    }

    func testCmdWRoutesToMainMenuWhenWebViewIsFirstResponder() {
        let spy = ActionSpy()
        installMenu(spy: spy, key: "w", modifiers: [.command])

        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let event = makeKeyDownEvent(key: "w", modifiers: [.command], keyCode: 13) // kVK_ANSI_W
        XCTAssertNotNil(event)

        XCTAssertTrue(webView.performKeyEquivalent(with: event!))
        XCTAssertTrue(spy.invoked)
    }

    func testCmdRRoutesToMainMenuWhenWebViewIsFirstResponder() {
        let spy = ActionSpy()
        installMenu(spy: spy, key: "r", modifiers: [.command])

        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let event = makeKeyDownEvent(key: "r", modifiers: [.command], keyCode: 15) // kVK_ANSI_R
        XCTAssertNotNil(event)

        XCTAssertTrue(webView.performKeyEquivalent(with: event!))
        XCTAssertTrue(spy.invoked)
    }

    private func installMenu(spy: ActionSpy, key: String, modifiers: NSEvent.ModifierFlags) {
        let mainMenu = NSMenu()

        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")

        let item = NSMenuItem(title: "Test Item", action: #selector(ActionSpy.didInvoke(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = spy
        fileMenu.addItem(item)

        mainMenu.addItem(fileItem)
        mainMenu.setSubmenu(fileMenu, for: fileItem)

        // Ensure NSApp exists and has a menu for performKeyEquivalent to consult.
        _ = NSApplication.shared
        NSApp.mainMenu = mainMenu
    }

    private func makeKeyDownEvent(key: String, modifiers: NSEvent.ModifierFlags, keyCode: UInt16) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: key,
            charactersIgnoringModifiers: key,
            isARepeat: false,
            keyCode: keyCode
        )
    }
}

final class FinderServicePathResolverTests: XCTestCase {
    func testOrderedUniqueDirectoriesUsesParentForFilesAndDedupes() {
        let input: [URL] = [
            URL(fileURLWithPath: "/tmp/cmuxterm-services/project", isDirectory: true),
            URL(fileURLWithPath: "/tmp/cmuxterm-services/project/README.md", isDirectory: false),
            URL(fileURLWithPath: "/tmp/cmuxterm-services/../cmuxterm-services/project", isDirectory: true),
            URL(fileURLWithPath: "/tmp/cmuxterm-services/other", isDirectory: true),
        ]

        let directories = FinderServicePathResolver.orderedUniqueDirectories(from: input)
        XCTAssertEqual(
            directories,
            [
                "/tmp/cmuxterm-services/project",
                "/tmp/cmuxterm-services/other",
            ]
        )
    }

    func testOrderedUniqueDirectoriesPreservesFirstSeenOrder() {
        let input: [URL] = [
            URL(fileURLWithPath: "/tmp/cmuxterm-services/b", isDirectory: true),
            URL(fileURLWithPath: "/tmp/cmuxterm-services/a/file.txt", isDirectory: false),
            URL(fileURLWithPath: "/tmp/cmuxterm-services/a", isDirectory: true),
            URL(fileURLWithPath: "/tmp/cmuxterm-services/b/file.txt", isDirectory: false),
        ]

        let directories = FinderServicePathResolver.orderedUniqueDirectories(from: input)
        XCTAssertEqual(
            directories,
            [
                "/tmp/cmuxterm-services/b",
                "/tmp/cmuxterm-services/a",
            ]
        )
    }
}

final class BrowserSearchEngineTests: XCTestCase {
    func testGoogleSearchURL() throws {
        let url = try XCTUnwrap(BrowserSearchEngine.google.searchURL(query: "hello world"))
        XCTAssertEqual(url.host, "www.google.com")
        XCTAssertEqual(url.path, "/search")
        XCTAssertTrue(url.absoluteString.contains("q=hello%20world"))
    }

    func testDuckDuckGoSearchURL() throws {
        let url = try XCTUnwrap(BrowserSearchEngine.duckduckgo.searchURL(query: "hello world"))
        XCTAssertEqual(url.host, "duckduckgo.com")
        XCTAssertEqual(url.path, "/")
        XCTAssertTrue(url.absoluteString.contains("q=hello%20world"))
    }

    func testBingSearchURL() throws {
        let url = try XCTUnwrap(BrowserSearchEngine.bing.searchURL(query: "hello world"))
        XCTAssertEqual(url.host, "www.bing.com")
        XCTAssertEqual(url.path, "/search")
        XCTAssertTrue(url.absoluteString.contains("q=hello%20world"))
    }
}

final class BrowserHistoryStoreTests: XCTestCase {
    func testRecordVisitDedupesAndSuggests() async throws {
        let store = await MainActor.run { BrowserHistoryStore(fileURL: nil) }

        let u1 = try XCTUnwrap(URL(string: "https://example.com/foo"))
        let u2 = try XCTUnwrap(URL(string: "https://example.com/bar"))

        await MainActor.run {
            store.recordVisit(url: u1, title: "Example Foo")
            store.recordVisit(url: u2, title: "Example Bar")
            store.recordVisit(url: u1, title: "Example Foo Updated")
        }

        let suggestions = await MainActor.run { store.suggestions(for: "foo", limit: 10) }
        XCTAssertEqual(suggestions.first?.url, "https://example.com/foo")
        XCTAssertEqual(suggestions.first?.visitCount, 2)
        XCTAssertEqual(suggestions.first?.title, "Example Foo Updated")
    }
}

final class OmnibarStateMachineTests: XCTestCase {
    func testEscapeRevertsWhenEditingThenBlursOnSecondEscape() throws {
        var state = OmnibarState()

        var effects = omnibarReduce(state: &state, event: .focusGained(currentURLString: "https://example.com/"))
        XCTAssertTrue(state.isFocused)
        XCTAssertEqual(state.buffer, "https://example.com/")
        XCTAssertFalse(state.isUserEditing)
        XCTAssertTrue(effects.shouldSelectAll)

        effects = omnibarReduce(state: &state, event: .bufferChanged("exam"))
        XCTAssertTrue(state.isUserEditing)
        XCTAssertEqual(state.buffer, "exam")
        XCTAssertTrue(effects.shouldRefreshSuggestions)

        // Simulate an open popup.
        effects = omnibarReduce(
            state: &state,
            event: .suggestionsUpdated([.search(engineName: "Google", query: "exam")])
        )
        XCTAssertEqual(state.suggestions.count, 1)
        XCTAssertFalse(effects.shouldSelectAll)

        // First escape: revert + close popup + select-all.
        effects = omnibarReduce(state: &state, event: .escape)
        XCTAssertEqual(state.buffer, "https://example.com/")
        XCTAssertFalse(state.isUserEditing)
        XCTAssertTrue(state.suggestions.isEmpty)
        XCTAssertTrue(effects.shouldSelectAll)
        XCTAssertFalse(effects.shouldBlurToWebView)

        // Second escape: blur (since we're not editing and popup is closed).
        effects = omnibarReduce(state: &state, event: .escape)
        XCTAssertTrue(effects.shouldBlurToWebView)
    }

    func testPanelURLChangeDoesNotClobberUserBufferWhileEditing() throws {
        var state = OmnibarState()
        _ = omnibarReduce(state: &state, event: .focusGained(currentURLString: "https://a.test/"))
        _ = omnibarReduce(state: &state, event: .bufferChanged("hello"))
        XCTAssertTrue(state.isUserEditing)

        _ = omnibarReduce(state: &state, event: .panelURLChanged(currentURLString: "https://b.test/"))
        XCTAssertEqual(state.currentURLString, "https://b.test/")
        XCTAssertEqual(state.buffer, "hello")
        XCTAssertTrue(state.isUserEditing)

        let effects = omnibarReduce(state: &state, event: .escape)
        XCTAssertEqual(state.buffer, "https://b.test/")
        XCTAssertTrue(effects.shouldSelectAll)
    }

    func testFocusLostRevertsUnlessSuppressed() throws {
        var state = OmnibarState()
        _ = omnibarReduce(state: &state, event: .focusGained(currentURLString: "https://example.com/"))
        _ = omnibarReduce(state: &state, event: .bufferChanged("typed"))
        XCTAssertEqual(state.buffer, "typed")

        _ = omnibarReduce(state: &state, event: .focusLostPreserveBuffer(currentURLString: "https://example.com/"))
        XCTAssertEqual(state.buffer, "typed")

        _ = omnibarReduce(state: &state, event: .focusGained(currentURLString: "https://example.com/"))
        _ = omnibarReduce(state: &state, event: .bufferChanged("typed2"))
        _ = omnibarReduce(state: &state, event: .focusLostRevertBuffer(currentURLString: "https://example.com/"))
        XCTAssertEqual(state.buffer, "https://example.com/")
    }
}

@MainActor
final class NotificationDockBadgeTests: XCTestCase {
    func testDockBadgeLabelEnabledAndCounted() {
        XCTAssertEqual(TerminalNotificationStore.dockBadgeLabel(unreadCount: 1, isEnabled: true), "1")
        XCTAssertEqual(TerminalNotificationStore.dockBadgeLabel(unreadCount: 42, isEnabled: true), "42")
        XCTAssertEqual(TerminalNotificationStore.dockBadgeLabel(unreadCount: 100, isEnabled: true), "99+")
    }

    func testDockBadgeLabelHiddenWhenDisabledOrZero() {
        XCTAssertNil(TerminalNotificationStore.dockBadgeLabel(unreadCount: 0, isEnabled: true))
        XCTAssertNil(TerminalNotificationStore.dockBadgeLabel(unreadCount: 5, isEnabled: false))
    }

    func testNotificationBadgePreferenceDefaultsToEnabled() {
        let suiteName = "NotificationDockBadgeTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        XCTAssertTrue(NotificationBadgeSettings.isDockBadgeEnabled(defaults: defaults))

        defaults.set(false, forKey: NotificationBadgeSettings.dockBadgeEnabledKey)
        XCTAssertFalse(NotificationBadgeSettings.isDockBadgeEnabled(defaults: defaults))

        defaults.set(true, forKey: NotificationBadgeSettings.dockBadgeEnabledKey)
        XCTAssertTrue(NotificationBadgeSettings.isDockBadgeEnabled(defaults: defaults))
    }
}


final class MenuBarBadgeLabelFormatterTests: XCTestCase {
    func testBadgeLabelFormatting() {
        XCTAssertNil(MenuBarBadgeLabelFormatter.badgeText(for: 0))
        XCTAssertEqual(MenuBarBadgeLabelFormatter.badgeText(for: 1), "1")
        XCTAssertEqual(MenuBarBadgeLabelFormatter.badgeText(for: 9), "9")
        XCTAssertEqual(MenuBarBadgeLabelFormatter.badgeText(for: 10), "9+")
        XCTAssertEqual(MenuBarBadgeLabelFormatter.badgeText(for: 47), "9+")
    }
}

final class MenuBarBuildHintFormatterTests: XCTestCase {
    func testReleaseBuildShowsNoHint() {
        XCTAssertNil(MenuBarBuildHintFormatter.menuTitle(appName: "cmuxterm DEV menubar-extra", isDebugBuild: false))
    }

    func testDebugBuildWithTagShowsTag() {
        XCTAssertEqual(
            MenuBarBuildHintFormatter.menuTitle(appName: "cmuxterm DEV menubar-extra", isDebugBuild: true),
            "Build Tag: menubar-extra"
        )
    }

    func testDebugBuildWithoutTagShowsUntagged() {
        XCTAssertEqual(
            MenuBarBuildHintFormatter.menuTitle(appName: "cmuxterm DEV", isDebugBuild: true),
            "Build: DEV (untagged)"
        )
    }
}

final class MenuBarNotificationLineFormatterTests: XCTestCase {
    func testPlainTitleContainsUnreadDotBodyAndTab() {
        let notification = TerminalNotification(
            id: UUID(),
            tabId: UUID(),
            surfaceId: nil,
            title: "Build finished",
            subtitle: "",
            body: "All checks passed",
            createdAt: Date(timeIntervalSince1970: 0),
            isRead: false
        )

        let line = MenuBarNotificationLineFormatter.plainTitle(notification: notification, tabTitle: "workspace-1")
        XCTAssertTrue(line.hasPrefix("● Build finished"))
        XCTAssertTrue(line.contains("All checks passed"))
        XCTAssertTrue(line.contains("workspace-1"))
    }

    func testPlainTitleFallsBackToSubtitleWhenBodyEmpty() {
        let notification = TerminalNotification(
            id: UUID(),
            tabId: UUID(),
            surfaceId: nil,
            title: "Deploy",
            subtitle: "staging",
            body: "",
            createdAt: Date(timeIntervalSince1970: 0),
            isRead: true
        )

        let line = MenuBarNotificationLineFormatter.plainTitle(notification: notification, tabTitle: nil)
        XCTAssertTrue(line.hasPrefix("  Deploy"))
        XCTAssertTrue(line.contains("staging"))
    }
}


final class MenuBarIconDebugSettingsTests: XCTestCase {
    func testDisplayedUnreadCountUsesPreviewOverrideWhenEnabled() {
        let suiteName = "MenuBarIconDebugSettingsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: MenuBarIconDebugSettings.previewEnabledKey)
        defaults.set(7, forKey: MenuBarIconDebugSettings.previewCountKey)

        XCTAssertEqual(MenuBarIconDebugSettings.displayedUnreadCount(actualUnreadCount: 2, defaults: defaults), 7)
    }

    func testBadgeRenderConfigClampsInvalidValues() {
        let suiteName = "MenuBarIconDebugSettingsTests.Clamp.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(-100, forKey: MenuBarIconDebugSettings.badgeRectXKey)
        defaults.set(200, forKey: MenuBarIconDebugSettings.badgeRectYKey)
        defaults.set(-100, forKey: MenuBarIconDebugSettings.singleDigitFontSizeKey)
        defaults.set(100, forKey: MenuBarIconDebugSettings.multiDigitXAdjustKey)

        let config = MenuBarIconDebugSettings.badgeRenderConfig(defaults: defaults)
        XCTAssertEqual(config.badgeRect.origin.x, 0, accuracy: 0.001)
        XCTAssertEqual(config.badgeRect.origin.y, 20, accuracy: 0.001)
        XCTAssertEqual(config.singleDigitFontSize, 6, accuracy: 0.001)
        XCTAssertEqual(config.multiDigitXAdjust, 4, accuracy: 0.001)
    }

    func testBadgeRenderConfigUsesLegacySingleDigitXAdjustWhenNewKeyMissing() {
        let suiteName = "MenuBarIconDebugSettingsTests.LegacyX.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(2.5, forKey: MenuBarIconDebugSettings.legacySingleDigitXAdjustKey)

        let config = MenuBarIconDebugSettings.badgeRenderConfig(defaults: defaults)
        XCTAssertEqual(config.singleDigitXAdjust, 2.5, accuracy: 0.001)
    }
}

@MainActor

final class MenuBarIconRendererTests: XCTestCase {
    func testImageWidthDoesNotShiftWhenBadgeAppears() {
        let noBadge = MenuBarIconRenderer.makeImage(unreadCount: 0)
        let withBadge = MenuBarIconRenderer.makeImage(unreadCount: 2)

        XCTAssertEqual(noBadge.size.width, 18, accuracy: 0.001)
        XCTAssertEqual(withBadge.size.width, 18, accuracy: 0.001)
    }
}
