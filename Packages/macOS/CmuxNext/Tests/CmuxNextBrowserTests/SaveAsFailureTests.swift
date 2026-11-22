import Foundation
import Testing
@testable import CmuxNextBrowser

/// Save Link As… and Save Image As… that cannot start are never silent: on
/// both engines the tab hands the host a download that failed at once (the
/// `.download` intent), so the App's downloads list shows the same "Could
/// not download" notice as for any failed download.
@MainActor
@Suite(.serialized) struct SaveAsFailureTests {
    private final class Recorder: BrowserTabDelegate {
        var downloads: [BrowserDownload] = []
        func browserTab(_ tab: any BrowserTab, didRequest intent: BrowserTabIntent) {
            if case .download(let item) = intent { downloads.append(item) }
        }
    }

    private let chosen = URL(filePath: "/tmp/nx-save-as/picked name.zip")
    private let link = URL(string: "https://e.com/files/archive.zip")!

    private func cefTab(browser: Int32?) -> (CEFTab, Recorder) {
        let runtime = CEFRuntime.shared
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: "save-as-\(browser ?? 0)"), profile: .default),
                               runtime: runtime)
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(tab)
        let recorder = Recorder()
        tab.delegate = recorder
        if let browser { runtime.register(tab, browser: browser) }
        return (tab, recorder)
    }

    private func expectFailedSave(_ recorder: Recorder) {
        #expect(recorder.downloads.count == 1)
        guard let item = recorder.downloads.first else { return }
        #expect(item.filename == "picked name.zip")
        if case .failed = item.status {} else { Issue.record("status is \(item.status), expected failed") }
    }

    /// The shim cannot start the download (no shim loaded here): the Bool
    /// `CEFDownloads.save` returns must reach the person.
    @Test func chromiumSaveTheShimCannotStartFails() {
        let (tab, recorder) = cefTab(browser: 70_301)
        defer { CEFRuntime.shared.tabsByBrowser[70_301] = nil }
        tab.save(link, to: chosen)
        expectFailedSave(recorder)
    }

    /// A tab whose page was never created cannot download.
    @Test func chromiumSaveWithoutAPageFails() {
        let (tab, recorder) = cefTab(browser: nil)
        tab.save(link, to: chosen)
        expectFailedSave(recorder)
    }

    /// Only web addresses are saved, on both engines alike.
    @Test func bothEnginesRefuseANonWebAddress() {
        let local = URL(filePath: "/etc/passwd")
        let (cef, cefRecorder) = cefTab(browser: nil)
        cef.save(local, to: chosen)
        expectFailedSave(cefRecorder)

        let webKit = WebKitEngine().makeWebKitTab(profile: .default)
        let webKitRecorder = Recorder()
        webKit.delegate = webKitRecorder
        webKit.save(local, to: chosen)
        expectFailedSave(webKitRecorder)
    }
}
