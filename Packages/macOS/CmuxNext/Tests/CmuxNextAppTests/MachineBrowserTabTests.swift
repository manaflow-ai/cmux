import AppKit
@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextRemote
import Foundation
import Testing

/// cx-2cob slice 1 (Lawrence: a browser in a machine's workspace runs on that
/// machine): New Browser Tab in another machine's workspace opens a tab whose
/// record is `cmux://remote-browser?machine=<id>`. Until the machine has a
/// browser host the tab shows why it is not ready, keeps a typed address,
/// and offers Open Locally Instead (this Mac's tab, slice 1a) and Retry.
/// Never a silent local tab.
@MainActor
struct MachineBrowserTabTests {
    // MARK: Record

    @Test func theRecordNamesTheMachineAndTheFirstPage() throws {
        let record = MachineBrowserRecord(machine: "ssh-43e226fdd9a6", initialURL: URL(string: "https://www.google.com/"))
        let parsed = try #require(MachineBrowserRecord(url: record.url))
        #expect(parsed == record)
        #expect(record.url.scheme == "cmux" && record.url.host() == "remote-browser")
        #expect(MachineBrowserRecord(machine: "vm-1", initialURL: nil).url.absoluteString == "cmux://remote-browser?machine=vm-1")
    }

    @Test func otherRecordsAndPagesAreNotMachineRecords() {
        #expect(MachineBrowserRecord(url: URL(string: "cmux://remote-browser?address=127.0.0.1:4103")!) == nil, "the loopback dev record")
        #expect(MachineBrowserRecord(url: URL(string: "https://www.google.com/")!) == nil)
        #expect(MachineBrowserRecord(url: URL(string: "cmux://remote-browser?machine=")!) == nil)
        // The first page is a web page only.
        let record = MachineBrowserRecord(url: URL(string: "cmux://remote-browser?machine=vm-1&url=file:///etc/passwd")!)
        #expect(record?.initialURL == nil)
    }

    // MARK: Placement

    @Test func aTabInAnotherMachinesWorkspaceGoesToThatMachine() {
        #expect(BrowserPlacement.resolve(isLocal: true, machine: "local") == .local)
        #expect(BrowserPlacement.resolve(isLocal: false, machine: "vm-1") == .machine("vm-1"))
        let google = URL(string: "https://www.google.com/")
        #expect(BrowserPlacement.machine("vm-1").address(for: google) == MachineBrowserRecord(machine: "vm-1", initialURL: google).url)
        #expect(BrowserPlacement.local.address(for: google) == google)
        #expect(BrowserPlacement.local.address(for: nil) == nil)
        // A Chromium internal page or a file is never sent to a machine record.
        #expect(BrowserPlacement.machine("vm-1").address(for: URL(string: "file:///tmp/a.html")) == URL(string: "file:///tmp/a.html"))
    }

    // MARK: Not ready

    @Test func theStateSaysWhyTheMachineHasNoBrowser() {
        #expect(MachineBrowserState.resolve(name: "box", isCloud: false, connected: true, hostReady: false) == .notInstalled("box"))
        #expect(MachineBrowserState.resolve(name: "vm", isCloud: true, connected: true, hostReady: false) == .unavailable("vm"))
        #expect(MachineBrowserState.resolve(name: "box", isCloud: false, connected: false, hostReady: false) == .notConnected("box"))
        #expect(MachineBrowserState.resolve(name: "box", isCloud: false, connected: true, hostReady: true) == .ready)
        #expect(MachineBrowserState.notInstalled("box").message.contains("box"))
    }

    @Test func aTypedAddressWaitsAndOpenLocallyTakesIt() throws {
        var opened: [URL?] = []
        var retries = 0
        let page = MachineBrowserPageTab(
            id: BrowserTabID(rawValue: "tab_1"), engine: .webkit, profile: .default,
            record: MachineBrowserRecord(machine: "vm-1", initialURL: nil),
            state: { retries += 1; return .unavailable("vm") },
            openLocally: { opened.append($0) })
        #expect(page.state.title == MachineBrowserStrings.notReadyTitle)
        page.load(try #require(URL(string: "https://www.google.com/")))
        #expect(page.queuedURL == URL(string: "https://www.google.com/"))
        #expect(page.state.url == URL(string: "https://www.google.com/"), "the omnibar keeps the typed address")
        page.reload()
        #expect(retries == 3, "checked when built, when the address changed, and on Retry")
        page.openLocally()
        #expect(opened == [URL(string: "https://www.google.com/")])
    }

    // MARK: Page for a record

    @Test func onlyAMachinesOwnRecordBecomesItsPage() {
        let record = MachineBrowserRecord(machine: "ssh-a", initialURL: nil)
        #expect(MachineBrowserRecord.owned(record.url.absoluteString, byMachine: "ssh-a") == record)
        #expect(MachineBrowserRecord.owned(record.url.absoluteString, byMachine: "ssh-b") == nil,
                "a machine's record never names another machine")
        #expect(MachineBrowserRecord.owned("https://example.com/", byMachine: "ssh-a") == nil)
    }
}
