import AppKit
import CmuxSettings
import Foundation
import Observation
import os
import SwiftUI
import Testing
@testable import CmuxSettingsUI

/// Regression coverage for https://github.com/manaflow-ai/cmux/issues/12134:
/// opening Settings beachballed for seconds on Intel Macs because the
/// first synchronous layout pass — the one `NSWindow(contentViewController:)`
/// runs before the window is ordered front — materialized every section's
/// AppKit-backed controls at once.
///
/// Hosts ``SettingsWindowRoot`` exactly the way the app's window factory
/// does. The window shows one section at a time (issue #11484), so only
/// the selected section's controls may exist, both in the synchronous
/// pass and after it, and navigation into a section that is not mounted
/// yet must mount it on demand.
///
/// Tests are `async` and wait on the mount model's observation signals:
/// the main run loop keeps turning while a test is suspended, which is
/// what drives SwiftUI's renders. The suite time limit bounds the failure
/// path only, so every wait honors cancellation.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(3))) struct SettingsWindowColdMountTests {
    /// Per-test settings stack. `defaults` also backs the root's `@AppStorage`
    /// (selected section, sidebar entry) through `.defaultAppStorage`, so
    /// one test's restore navigation cannot leak into the next.
    struct Fixture {
        let runtime: SettingsRuntime
        let defaults: UserDefaults
    }

    static func makeFixture() -> Fixture {
        let suiteName = "SettingsWindowColdMountTests.\(UUID().uuidString)"
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

    static func makeMountModel(initial: SettingsSectionID = .account) -> SettingsSectionMountModel {
        SettingsSectionMountModel(initial: initial, order: SettingsWindowRoot.mountOrder(cloudAvailable: false))
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
        let window = NSWindow(contentViewController: hosting)
        window.setContentSize(NSSize(width: 980, height: 680))
        window.contentView?.layoutSubtreeIfNeeded()
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        window.orderBack(nil)
        return window
    }

    /// Suspends until `condition` holds, waking on every change to the
    /// model's mount state — a real signal, not a poll. Returns early when
    /// the suite time limit cancels the test, so a condition that never
    /// holds fails the test instead of hanging the runner.
    static func wait(
        for model: SettingsSectionMountModel,
        until condition: @escaping @MainActor () -> Bool
    ) async {
        while !condition(), !Task.isCancelled {
            let pending = OSAllocatedUnfairLock<CheckedContinuation<Void, Never>?>(initialState: nil)
            let resume: @Sendable () -> Void = { pending.withLock { $0.take() }?.resume() }
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    pending.withLock { $0 = continuation }
                    withObservationTracking {
                        _ = model.mounted
                        _ = model.deferredScroll
                        _ = model.pinnedScroll
                    } onChange: {
                        resume()
                    }
                    if Task.isCancelled { resume() }
                }
            } onCancel: {
                resume()
            }
        }
    }

    @Test func onlyTheSelectedSectionIsEverBuilt() async {
        let fixture = Self.makeFixture()
        let model = Self.makeMountModel()
        let window = Self.host(SettingsWindowRoot(runtime: fixture.runtime, mountModel: model), in: fixture)
        defer { window.orderOut(nil) }
        let accountControls = Self.controlCount(in: window.contentView)
        #expect(model.mounted == [.account])

        NotificationCenter.default.post(
            name: SettingsWindowRoot.navigationRequestName,
            object: nil,
            userInfo: ["target": SettingsSectionID.keyboardShortcuts.rawValue]
        )
        await Self.wait(for: model) { model.isMounted(.keyboardShortcuts) && model.deferredScroll == nil }
        window.contentView?.layoutSubtreeIfNeeded()
        let shortcutControls = Self.controlCount(in: window.contentView)

        // Mounting records that a section was built once; only the
        // selected one is in the hierarchy, so the window never carries
        // the couple of hundred controls of the full settings tree.
        #expect(!model.isMounted(.workspaceColors))
        #expect(shortcutControls != accountControls, "pane did not switch: \(shortcutControls) controls")
        #expect(shortcutControls < 100, "inactive sections are in the hierarchy: \(shortcutControls) controls")

        // Returning to a section mounted on an earlier visit rebuilds its
        // pane, so the scroll still waits for that content to appear.
        for section in [SettingsSectionID.account, .keyboardShortcuts] {
            NotificationCenter.default.post(
                name: SettingsWindowRoot.navigationRequestName,
                object: nil,
                userInfo: ["target": section.rawValue]
            )
            #expect(model.deferredScroll?.section == section)
            await Self.wait(for: model) { model.deferredScroll == nil }
        }
    }

    @Test func navigatingToAnUnmountedSectionMountsItOnDemand() async {
        let fixture = Self.makeFixture()
        let model = Self.makeMountModel()
        let window = Self.host(SettingsWindowRoot(runtime: fixture.runtime, mountModel: model), in: fixture)
        defer { window.orderOut(nil) }
        #expect(!model.isMounted(.keyboardShortcuts))

        NotificationCenter.default.post(
            name: SettingsWindowRoot.navigationRequestName,
            object: nil,
            userInfo: [
                "target": SettingsSectionID.keyboardShortcuts.rawValue,
                "anchor": "setting:keyboardShortcuts:shortcuts",
                "highlight": true
            ]
        )
        await Self.wait(for: model) { model.isMounted(.keyboardShortcuts) }
        // Mounted on demand; sections in between stay unbuilt.
        #expect(!model.isMounted(.workspaceColors))
        #expect(model.pinnedScroll?.section == .keyboardShortcuts)
        // The scroll owed to the placeholder is paid once its content appears.
        await Self.wait(for: model) { model.deferredScroll == nil }
        #expect(model.deferredScroll == nil)
    }

    @Test func legacyComputersNavigationTargetsMobileComputersSubsection() async {
        let fixture = Self.makeFixture()
        let model = Self.makeMountModel()
        let window = Self.host(SettingsWindowRoot(runtime: fixture.runtime, mountModel: model), in: fixture)
        defer { window.orderOut(nil) }

        NotificationCenter.default.post(
            name: SettingsWindowRoot.navigationRequestName,
            object: nil,
            userInfo: [
                "target": SettingsSectionID.computers.rawValue,
                "highlight": true
            ]
        )

        await Self.wait(for: model) { model.pinnedScroll?.section == .mobile }
        #expect(model.pinnedScroll?.section == .mobile)
        #expect(model.pinnedScroll?.anchorID == "setting:mobile:computers")
    }

    @Test func targetedOpenDoesNotRestoreTheLastViewedSection() {
        let fixture = Self.makeFixture()
        // The user last looked at Keyboard Shortcuts; this open targets
        // Browser Import. The appear-time restore navigation must follow the
        // target, or the previous pane gets built in the first pass anyway.
        fixture.defaults.set(SettingsSectionID.keyboardShortcuts.rawValue, forKey: SettingsWindowRoot.selectedSectionDefaultsKey)
        fixture.defaults.set("section:\(SettingsSectionID.keyboardShortcuts.rawValue)", forKey: "selectedSettingsSidebarEntry")
        let model = Self.makeMountModel(initial: .browserImport)
        let window = Self.host(
            SettingsWindowRoot(runtime: fixture.runtime, initialSection: .browserImport, mountModel: model),
            in: fixture
        )
        defer { window.orderOut(nil) }

        #expect(model.mounted == [.browser], "first pass mounted \(model.mounted)")
        #expect(model.pinnedScroll?.section == .browserImport)
    }

    @Test func targetedOpenMountsTheTargetSectionFirst() {
        let fixture = Self.makeFixture()
        let accountWindow = Self.host(SettingsWindowRoot(runtime: fixture.runtime, initialSection: .account), in: fixture)
        defer { accountWindow.orderOut(nil) }
        let accountControls = Self.controlCount(in: accountWindow.contentView)

        // `browserImport` is an anchor inside the Browser section, whose
        // rows carry far more controls than the Account section.
        let browserWindow = Self.host(SettingsWindowRoot(runtime: fixture.runtime, initialSection: .browserImport), in: fixture)
        defer { browserWindow.orderOut(nil) }
        let browserControls = Self.controlCount(in: browserWindow.contentView)

        #expect(browserControls > accountControls + 10, "browser: \(browserControls), account: \(accountControls)")
    }
}
