import AppKit
import CmuxSettings
import Foundation
import SwiftUI
import Testing
@testable import CmuxSettingsUI

/// Hosts the real Settings content to verify inactive categories do not
/// leave their AppKit controls in the detail page, including on cold open.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(3))) struct SettingsWindowPageTests {
    /// Per-test settings stack. `defaults` also backs the root's `@AppStorage`
    /// (selected section, sidebar entry) through `.defaultAppStorage`, so
    /// one test's restore navigation cannot leak into the next.
    struct Fixture {
        let runtime: SettingsRuntime
        let defaults: UserDefaults
    }

    static func makeFixture() -> Fixture {
        let suiteName = "SettingsWindowPageTests.\(UUID().uuidString)"
        // Two handles on the same suite: `UserDefaults` is not Sendable, so
        // the instance handed to the store actor cannot be reused here.
        let runtime = SettingsRuntime(
            catalog: SettingCatalog(),
            userDefaultsStore: UserDefaultsSettingsStore(defaults: UserDefaults(suiteName: suiteName)!),
            jsonStore: JSONConfigStore(
                fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
            ),
            secretStore: SecretFileStore(
                baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            ),
            errorLog: SettingsErrorLog()
        )
        return Fixture(runtime: runtime, defaults: UserDefaults(suiteName: suiteName)!)
    }

    /// AppKit-backed controls (`NSSwitch`, `NSPopUpButton`, `NSStepper`,
    /// `NSColorWell`, `NSButton`, …) currently attached under `view`.
    static func controlCount(in view: NSView?) -> Int {
        guard let view else { return 0 }
        return (view is NSControl ? 1 : 0) + view.subviews.reduce(0) { $0 + controlCount(in: $1) }
    }

    /// Hosts `root` the way `SettingsWindowFactory.makeSettingsWindow` does:
    /// `NSWindow(contentViewController:)` runs the first layout pass
    /// synchronously, before any run-loop turn. The window is then ordered
    /// in off screen so SwiftUI treats the content as presented.
    static func host(_ root: SettingsWindowRoot, in fixture: Fixture) -> NSWindow {
        let hosting = NSHostingController(rootView: root.defaultAppStorage(fixture.defaults))
        hosting.sceneBridgingOptions = [.title]
        let window = NSWindow(contentViewController: hosting)
        window.styleMask.insert(.fullSizeContentView)
        window.toolbar = NSToolbar(identifier: "SettingsWindowPageTests")
        window.setContentSize(NSSize(width: 980, height: 680))
        window.contentView?.layoutSubtreeIfNeeded()
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        window.orderBack(nil)
        return window
    }

    @Test func categoryPagesReplaceTheirControls() throws {
        let fixture = Self.makeFixture()
        let window = Self.host(SettingsWindowRoot(runtime: fixture.runtime, initialSection: .account), in: fixture)
        defer { window.close() }
        let accountControls = Self.controlCount(in: window.contentView)

        Self.navigate(to: .browser, in: window)
        let browserControls = Self.controlCount(in: window.contentView)
        #expect(browserControls > accountControls + 10)
        let browserScroll = try #require(Self.scrollViews(in: window.contentView).max {
            ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0)
        })
        let top = try #require(Self.controls(in: browserScroll.documentView).map {
            $0.convert($0.bounds, to: nil).maxY
        }.max())
        #expect(top <= window.contentLayoutRect.maxY + 1)

        Self.navigate(to: .account, in: window)
        #expect(Self.controlCount(in: window.contentView) == accountControls)
    }

    @Test func browserImportHasItsOwnPage() {
        let fixture = Self.makeFixture()
        let browser = Self.host(SettingsWindowRoot(runtime: fixture.runtime, initialSection: .browser), in: fixture)
        defer { browser.close() }
        let importPage = Self.host(SettingsWindowRoot(runtime: fixture.runtime, initialSection: .browserImport), in: fixture)
        defer { importPage.close() }

        let browserControls = Self.controlCount(in: browser.contentView)
        let importControls = Self.controlCount(in: importPage.contentView)
        #expect(importControls > 0)
        #expect(browserControls > importControls + 10)
    }

    @Test func targetedOpenDoesNotBuildTheLastViewedPage() {
        let fixture = Self.makeFixture()
        fixture.defaults.set(SettingsSectionID.browser.rawValue, forKey: SettingsWindowRoot.selectedSectionDefaultsKey)
        let targeted = Self.host(SettingsWindowRoot(runtime: fixture.runtime, initialSection: .account), in: fixture)
        defer { targeted.close() }
        let targetedControls = Self.controlCount(in: targeted.contentView)

        let account = Self.host(SettingsWindowRoot(runtime: fixture.runtime, initialSection: .account), in: fixture)
        defer { account.close() }
        #expect(targetedControls == Self.controlCount(in: account.contentView))
        #expect(fixture.defaults.string(forKey: SettingsWindowRoot.selectedSectionDefaultsKey) == SettingsSectionID.account.rawValue)
    }

    @Test func searchNavigationScrollsWithinTheNewPage() throws {
        let fixture = Self.makeFixture()
        let window = Self.host(SettingsWindowRoot(runtime: fixture.runtime, initialSection: .account), in: fixture)
        defer { window.close() }
        NotificationCenter.default.post(
            name: SettingsWindowRoot.navigationRequestName,
            object: nil,
            userInfo: [
                "target": SettingsSectionID.browser.rawValue,
                "anchor": "setting:browser:http-allowlist",
                "highlight": true
            ]
        )
        window.contentView?.layoutSubtreeIfNeeded()
        let scroll = try #require(Self.scrollViews(in: window.contentView).max {
            ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0)
        })
        #expect(scroll.documentVisibleRect.minY > 100)

        Self.navigate(to: .browser, in: window)
        let resetScroll = try #require(Self.scrollViews(in: window.contentView).max {
            ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0)
        })
        #expect(resetScroll.documentVisibleRect.minY < 30)
        let top = try #require(Self.controls(in: resetScroll.documentView).map {
            $0.convert($0.bounds, to: nil).maxY
        }.max())
        #expect(top <= window.contentLayoutRect.maxY + 1)
    }

    @Test func browserDraftsSurvivePageReplacement() {
        let fixture = Self.makeFixture()
        let drafts = SettingsPageDrafts()
        drafts.httpAllowlistLoaded = true
        drafts.httpAllowlistDraft = "unsaved-http.example"
        drafts.urlAllowlistLoaded = true
        drafts.urlAllowlistDraft = "unsaved-url.example"
        let window = Self.host(
            SettingsWindowRoot(runtime: fixture.runtime, initialSection: .browser, pageDrafts: drafts),
            in: fixture
        )
        defer { window.close() }

        Self.navigate(to: .account, in: window)
        Self.navigate(to: .browser, in: window)
        let editors = Self.textViews(in: window.contentView).map(\.string)
        #expect(editors.contains("unsaved-http.example"))
        #expect(editors.contains("unsaved-url.example"))
    }

    private static func controls(in view: NSView?) -> [NSControl] {
        guard let view else { return [] }
        return ((view as? NSControl).map { [$0] } ?? [])
            + view.subviews.flatMap { controls(in: $0) }
    }

    private static func textViews(in view: NSView?) -> [NSTextView] {
        guard let view else { return [] }
        return ((view as? NSTextView).map { [$0] } ?? [])
            + view.subviews.flatMap { textViews(in: $0) }
    }

    private static func scrollViews(in view: NSView?) -> [NSScrollView] {
        guard let view else { return [] }
        return ((view as? NSScrollView).map { [$0] } ?? [])
            + view.subviews.flatMap { scrollViews(in: $0) }
    }

    private static func navigate(to section: SettingsSectionID, in window: NSWindow) {
        NotificationCenter.default.post(
            name: SettingsWindowRoot.navigationRequestName,
            object: nil,
            userInfo: ["target": section.rawValue]
        )
        window.contentView?.layoutSubtreeIfNeeded()
    }
}
