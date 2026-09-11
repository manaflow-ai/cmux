import AppKit
import CmuxSettings
import Foundation
import Observation
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
/// does and compares the controls present after that synchronous pass with
/// the controls present once the run loop has mounted the remaining
/// sections. The synchronous pass must be a small fraction of the full
/// tree, the rest must arrive one section per turn, and navigation into a
/// section that is still a placeholder must mount it on demand.
///
/// Tests are `async` and wait on the mount model's observation signals:
/// the main run loop keeps turning while a test is suspended, which is
/// what drives SwiftUI's renders and the chained mounts. The suite time
/// limit bounds the failure path only.
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
    /// model's mount state — a real signal, not a poll.
    static func wait(
        for model: SettingsSectionMountModel,
        until condition: @escaping @MainActor () -> Bool
    ) async {
        while !condition() {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                withObservationTracking {
                    _ = model.mounted
                    _ = model.deferredScroll
                    _ = model.isComplete
                } onChange: {
                    continuation.resume()
                }
            }
        }
    }

    @Test func synchronousColdHostMountsOnlyAFractionOfTheControls() async {
        let fixture = Self.makeFixture()
        let model = Self.makeMountModel()
        let window = Self.host(SettingsWindowRoot(runtime: fixture.runtime, mountModel: model), in: fixture)
        defer { window.orderOut(nil) }

        let synchronousControls = Self.controlCount(in: window.contentView)
        await Self.wait(for: model) { model.isComplete }
        let mountedControls = Self.controlCount(in: window.contentView)

        // The complete tree carries a couple of hundred AppKit-backed
        // controls; the pass that blocks window creation may hold only the
        // sidebar plus the section the window opens on.
        #expect(mountedControls > 100, "progressive mounting must still deliver every section (\(mountedControls) controls)")
        #expect(
            synchronousControls * 4 < mountedControls,
            "window creation materialized \(synchronousControls) of \(mountedControls) controls synchronously"
        )
    }

    @Test func remainingSectionsMountOneAtATimeAfterTheWindowExists() async {
        let fixture = Self.makeFixture()
        let model = Self.makeMountModel()
        let window = Self.host(SettingsWindowRoot(runtime: fixture.runtime, mountModel: model), in: fixture)
        defer { window.orderOut(nil) }

        #expect(model.mounted == [.account])

        // Every run-loop turn may add at most one section: sample the
        // mounted set as the chain advances and reject any jump of two.
        var sizes: [Int] = [model.mounted.count]
        await Self.wait(for: model) {
            let count = model.mounted.count
            if count != sizes.last { sizes.append(count) }
            return model.isComplete
        }
        #expect(model.isComplete)
        #expect(model.mounted == Set(model.order))
        #expect(zip(sizes, sizes.dropFirst()).allSatisfy { $1 - $0 == 1 }, "sections mounted in bursts: \(sizes)")
    }

    @Test func navigatingToAnUnmountedSectionMountsItAheadOfTheChain() async {
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
        // Mounted on demand, not because the chain happened to reach it.
        #expect(!model.isMounted(.workspaceColors))
        #expect(model.pinnedScroll?.section == .keyboardShortcuts)
        // The scroll owed to the placeholder is paid once its content appears.
        await Self.wait(for: model) { model.deferredScroll == nil }
        #expect(model.deferredScroll == nil)
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
