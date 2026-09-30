import AppKit
import Testing
@testable import CmuxNextBrowser

/// Chrome's "extension crashed, click to reload".
@MainActor @Suite struct ExtensionCrashTests {
    final class Backend: BrowserExtensionBackend {
        var list: [BrowserExtensionInfo]
        var calls: [String] = []
        init(_ list: [BrowserExtensionInfo]) { self.list = list }
        var supportsManagement: Bool { true }
        func snapshot() -> (extensions: [BrowserExtensionInfo], commands: [BrowserExtensionCommand])? { (list, []) }
        func setEnabled(_ id: String, _ enabled: Bool) -> Bool {
            calls.append("\(id)=\(enabled)")
            if let index = list.firstIndex(where: { $0.id == id }) {
                list[index].isTerminated = false
                list[index].isEnabled = enabled
            }
            return true
        }
        func uninstall(_ id: String) -> Bool { false }
        func setPinned(_ id: String, _ pinned: Bool) -> Bool { false }
        func openOptions(_ id: String, from tab: (any BrowserTab)?) -> Bool { false }
        func loadUnpacked(at path: String) -> Bool { false }
        func runCommand(_ command: BrowserExtensionCommand, in tab: any BrowserTab) -> Bool { false }
    }

    @Test func aTerminatedExtensionShowsTheCrashButtonAndClickReloadsIt() {
        let backend = Backend([
            BrowserExtensionInfo(id: "a", name: "Alpha", isEnabled: false, isTerminated: true),
            BrowserExtensionInfo(id: "b", name: "Beta"),
        ])
        let store = BrowserExtensionStore(profile: .default, backend: backend)
        store.refresh()
        #expect(store.crashed.map(\.id) == ["a"])

        let slot = NSStackView()
        let puzzle = NSView()
        slot.addArrangedSubview(puzzle)
        let indicator = ExtensionCrashIndicator()
        indicator.update(store: store, in: slot, before: puzzle)
        #expect(slot.arrangedSubviews.first === indicator.button)
        #expect(indicator.button.toolTip?.contains("Alpha") == true)

        indicator.reloadCrashed()
        #expect(backend.calls == ["a=false", "a=true"])
        #expect(store.crashed.isEmpty)
        indicator.update(store: store, in: slot, before: puzzle)
        #expect(!slot.arrangedSubviews.contains(indicator.button))
    }
}
