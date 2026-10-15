import Foundation
import Testing
@testable import CmuxBrowser

@MainActor
private final class MockExtensionBackend: BrowserExtensionBackend {
    var supportsManagement = true
    var supportsPinnedOrder = false
    var live = true
    var extensions: [BrowserExtensionInfo] = []
    var commands: [BrowserExtensionCommand] = []
    var ranCommands: [String] = []
    var accept = true

    func snapshot() -> (extensions: [BrowserExtensionInfo], commands: [BrowserExtensionCommand])? {
        live ? (extensions, commands) : nil
    }

    func setEnabled(_ id: String, _ enabled: Bool) -> Bool {
        mutate(id) { $0.isEnabled = enabled }
    }

    func uninstall(_ id: String) -> Bool {
        guard accept else { return false }
        extensions.removeAll { $0.id == id }
        return true
    }

    func reload(_ id: String) -> Bool { mutate(id) { $0.isTerminated = false } }
    func setPinned(_ id: String, _ pinned: Bool) -> Bool { mutate(id) { $0.isPinned = pinned } }
    func openOptions(_ id: String, from tab: (any BrowserExtensionTab)?) -> Bool { accept }

    func loadUnpacked(at path: String) -> Bool {
        guard accept else { return false }
        extensions.append(BrowserExtensionInfo(id: "loaded", name: "Loaded", location: .unpacked, path: path))
        return true
    }

    func runCommand(_ command: BrowserExtensionCommand, in tab: any BrowserExtensionTab) -> Bool {
        ranCommands.append(command.name)
        return true
    }

    private func mutate(_ id: String, _ change: (inout BrowserExtensionInfo) -> Void) -> Bool {
        guard accept, let index = extensions.firstIndex(where: { $0.id == id }) else { return false }
        change(&extensions[index])
        return true
    }
}

@MainActor
private final class MockExtensionTab: BrowserExtensionTab {
    var requested: [String] = []
    func requestExtensionAction(_ extensionID: String) { requested.append(extensionID) }
}

@MainActor
@Suite("Browser extension store")
struct BrowserExtensionStoreTests {
    private func makeStore() -> (BrowserExtensionStore, MockExtensionBackend) {
        let backend = MockExtensionBackend()
        backend.extensions = [
            BrowserExtensionInfo(id: "aaa", name: "Alpha", hasAction: true),
            BrowserExtensionInfo(id: "bbb", name: "Beta", isTerminated: true),
        ]
        let store = BrowserExtensionStore(profileID: UUID(), backend: backend)
        store.refresh()
        return (store, backend)
    }

    @Test
    func refreshMirrorsBackendAndKeepsListsWhileNoBrowserIsLive() {
        let (store, backend) = makeStore()
        #expect(store.extensions.map(\.id) == ["aaa", "bbb"])
        #expect(store.crashed.map(\.id) == ["bbb"])
        backend.live = false
        backend.extensions = []
        store.refresh()
        #expect(store.extensions.count == 2)
    }

    @Test
    func mutationsRefreshTheMirror() {
        let (store, _) = makeStore()
        #expect(store.setPinned("aaa", true))
        #expect(store.extensions.first?.isPinned == true)
        #expect(store.setEnabled("aaa", false))
        #expect(store.extensions.first?.isEnabled == false)
        #expect(store.reload("bbb"))
        #expect(store.crashed.isEmpty)
        #expect(store.uninstall("aaa"))
        #expect(store.extensions.map(\.id) == ["bbb"])
        #expect(store.loadUnpacked(at: "/tmp/x"))
        #expect(store.extensionInfo(matching: "loaded")?.path == "/tmp/x")
    }

    @Test
    func unsupportedManagementRefusesEverything() {
        let (store, backend) = makeStore()
        backend.supportsManagement = false
        #expect(!store.setPinned("aaa", true))
        #expect(!store.uninstall("aaa"))
        #expect(!store.openOptions("aaa"))
        #expect(!store.loadUnpacked(at: "/tmp/x"))
        #expect(backend.extensions.count == 2)
    }

    @Test
    func movePinnedNeedsOrderSupport() {
        let (store, backend) = makeStore()
        #expect(!store.movePinned("aaa", to: 0))
        backend.supportsPinnedOrder = true
        #expect(!store.movePinned("aaa", to: 0), "mock keeps the protocol's default refusal")
    }

    @Test
    func lookupByIdThenCaseInsensitiveName() {
        let (store, _) = makeStore()
        #expect(store.extensionInfo(matching: "bbb")?.name == "Beta")
        #expect(store.extensionInfo(matching: "alpha")?.id == "aaa")
        #expect(store.extensionInfo(matching: "gamma") == nil)
    }

    @Test
    func executeActionClicksTheToolbarOthersDispatch() {
        let (store, backend) = makeStore()
        let tab = MockExtensionTab()
        let execute = BrowserExtensionCommand(extensionID: "aaa", name: "_execute_action", keyCode: 0, modifiers: 0)
        let custom = BrowserExtensionCommand(extensionID: "aaa", name: "toggle", keyCode: 0, modifiers: 0)
        #expect(store.run(execute, in: tab))
        #expect(store.run(custom, in: tab))
        #expect(tab.requested == ["aaa"])
        #expect(backend.ranCommands == ["toggle"])
    }
}
