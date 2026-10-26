import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextWakeups
import Foundation
import Testing

/// Task 028 of plans/cmux-next/chrome-parity/p01-process.md: the App's users of CEF types work with
/// both backends. Chromium's page is a child window of the cmux window only in process; in host mode
/// it is the pane's `ChromiumHostPageView`, a view like any other, so page-window code (focus through
/// the page window, the child-page geometry invariant, `debug.cef`'s child windows) has nothing to do
/// there, while a Chromium page still takes the keys as a Chromium page.
@MainActor @Suite(.serialized) struct ChromiumBackendAppTests {
    @Test(arguments: [false, true])
    func aChromiumPageIsAChildWindowOnlyInProcess(hostMode: Bool) throws {
        let rig = try Rig(hostMode: hostMode)
        defer { rig.close() }
        let content = TabContent.browser(BrowserEntry(tab: rig.tab, mainWork: MainWorkScheduler(budget: MainFrameBudget()), node: nil))

        #expect(rig.tab.presentation == (hostMode ? .inView : .childWindow))
        #expect(content.chromiumTab === rig.tab, "a Chromium tab takes the keys as a Chromium page in either backend")
        if hostMode {
            #expect(content.childWindowTab == nil, "host mode has no page window")
        } else {
            #expect(content.childWindowTab === rig.tab)
        }
    }

    @Test func aWebKitTabIsNoChromiumTab() {
        let tab = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory()).makeWebKitTab()
        let content = TabContent.browser(BrowserEntry(tab: tab, mainWork: MainWorkScheduler(budget: MainFrameBudget()), node: nil))
        #expect(content.chromiumTab == nil)
        #expect(content.childWindowTab == nil)
    }

    @Test func childPageGeometryChecksPageWindowsOnlyInProcess() {
        #expect(ChildPageGeometry.hasPageWindows(.inProcess))
        #expect(!ChildPageGeometry.hasPageWindows(.host))
    }

    @Test func theRuntimeServiceReportsTheBackendOfItsSource() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "chromium-backend-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // A bundle with no runtime and no pin: the service's source is the only thing read.
        let empty = try #require(Bundle(path: root.path))
        let work = BackgroundWork(label: "test.chromium-backend")
        let local = ChromiumRuntimeService.make(work: work, bundle: empty, environment: [:], applicationSupport: nil)
        #expect(local.backend == .inProcess)
        #expect(local.source.hostSupervisor == nil)
        let hosted = ChromiumRuntimeService.make(work: work, bundle: empty, environment: [:], applicationSupport: nil,
                                                 hostSupervisor: NeverAttachingSupervisor())
        #expect(hosted.backend == .host)
        #expect(hosted.source.hostSupervisor != nil)
    }

    /// A pane with one Chromium tab against a stand-in shim; host mode has a host start that never attaches.
    @MainActor final class Rig {
        let runtime: CEFRuntime
        let tab: CEFTab
        let root: URL

        init(hostMode: Bool) throws {
            root = FileManager.default.temporaryDirectory.appending(path: "chromium-backend-app-\(UUID().uuidString)", directoryHint: .isDirectory)
            runtime = CEFRuntime(shim: try CEFShimLibrary.resolving(NothingShim.symbol), storage: CEFProfileStorage(root: root))
            if hostMode { runtime.hostStart = CEFHostStart(supervisor: NeverAttachingSupervisor()) }
            // A tab's scheduled work reads the runtime through an unowned reference: it outlives the test.
            _ = Unmanaged.passRetained(runtime)
            let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
            host.endOfTurn = { $0() }
            tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
            host.add(tab)
        }

        func close() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}

/// Never attaches: these tests never start Chromium.
@MainActor private final class NeverAttachingSupervisor: ChromiumHostSupervising {
    func attachment() async throws(ChromiumHostAttachError) -> ChromiumHostAttachment {
        throw .cannotStart("not started in this test")
    }
}

/// Stand-in shim: every symbol returns 0.
private nonisolated enum NothingShim {
    static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        let nothing: @convention(c) () -> Int = { 0 }
        return unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
    }
}
