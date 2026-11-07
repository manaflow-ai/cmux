import AppKit
import CmuxNextFileGrid
@testable import CmuxNextScreenshots
import CmuxNextTestSupport
import Foundation
import Testing

/// Lawrence, 2026-11-02 (msg 19715): the Screenshots page showed "Show your screenshots?" again on every
/// relaunch. The click lived only in the process (`ScreenshotsGate`), so a relaunch forgot it. The click is
/// now remembered across launches: a later page lists as soon as it is on screen, with no card, and reads
/// nothing while it is not (a tab restored at launch: LAUNCH-NO-TCC-PROMPTS). The card comes back only when
/// access is really missing: every folder fails to read.
@MainActor @Suite(.serialized, .closesItsWindows) struct ScreenshotsRememberedAccessTests {
    private static func defaults() throws -> UserDefaults {
        let name = "ScreenshotsRememberedAccessTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private static func window(showing view: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = view
        return window
    }

    @Test func aClickIsRememberedByTheNextLaunch() throws {
        let defaults = try Self.defaults()
        let first = ScreenshotsGate(defaults: defaults)
        #expect(!first.remembersAccess)
        first.unlock("tab-a")
        let relaunched = ScreenshotsGate(defaults: defaults)
        #expect(relaunched.remembersAccess)
        // Still lazy: no folder is detected before a page is on screen.
        #expect(!relaunched.mayDetect)
    }

    @Test func aRememberedPageListsWhenShownAndReadsNothingBefore() throws {
        let defaults = try Self.defaults()
        ScreenshotsGate(defaults: defaults).unlock("tab-a")
        let gate = ScreenshotsGate(defaults: defaults)
        let model = gate.model(for: "tab-a")
        let view = ScreenshotsView(model: model, cache: ThumbnailCache(), workspace: SilentWorkspace())
        var shown = 0
        gate.wire(view, key: "tab-a") { shown += 1 }
        let readBeforeShown = model.isListing
        #expect(!readBeforeShown, "a page not on screen reads no folder")
        let window = Self.window(showing: view)
        defer { window.close() }
        let listing = model.isListing
        #expect(listing, "the remembered click lists with no card")
        let card = view.showsPrompt
        #expect(!card)
        #expect(shown == 1, "the app is told once, as for a click")
    }

    @Test func aFirstLaunchStillShowsTheCard() throws {
        let gate = ScreenshotsGate(defaults: try Self.defaults())
        let model = gate.model(for: "tab-a")
        let view = ScreenshotsView(model: model, cache: ThumbnailCache(), workspace: SilentWorkspace())
        gate.wire(view, key: "tab-a") {}
        let window = Self.window(showing: view)
        defer { window.close() }
        let listing = model.isListing
        #expect(!listing)
        let card = view.showsPrompt
        #expect(card)
    }

    @Test func whenNoFolderCanBeReadTheCardComesBackAndTheClickIsForgotten() async throws {
        let defaults = try Self.defaults()
        ScreenshotsGate(defaults: defaults).unlock("tab-a")
        let gate = ScreenshotsGate(defaults: defaults)
        let model = ScreenshotsModel(watcher: SilentWatcher(), listsAtOnce: false)
        let view = ScreenshotsView(model: model, cache: ThumbnailCache(), workspace: SilentWorkspace())
        gate.wire(view, key: "tab-a") {}
        // A folder this process may not list, as a Desktop macOS denies (EPERM); a missing folder lists as empty.
        let denied = try TemporaryFolder()
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: denied.url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: denied.url.path) }
        model.setSources([ScreenshotSource(id: "system", label: "Desktop", folder: denied.url, origin: .system, rule: ScreenshotScanRule())])
        let window = Self.window(showing: view)
        defer { window.close() }
        await model.refresh()
        // The view may already have reconciled through its observation of the model; a second call changes nothing.
        view.reconcileAccess()
        let card = view.showsPrompt
        #expect(card, "the card comes back when access is missing")
        #expect(!model.isListing)
        #expect(!ScreenshotsGate(defaults: defaults).remembersAccess, "the next launch asks again")
    }
}

@MainActor private final class SilentWorkspace: ScreenshotsWorkspace {
    func open(_ urls: [URL]) {}
    func reveal(_ urls: [URL]) {}
}
