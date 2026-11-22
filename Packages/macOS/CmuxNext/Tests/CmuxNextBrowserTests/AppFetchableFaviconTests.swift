import Foundation
import Testing
@testable import CmuxNextBrowser

/// The app fetches favicons in its own process, which reaches this Mac's
/// localhost. A tab whose store is a remote machine's (a machine store, a
/// Cloud proxied tab) must never have its loopback favicon fetched by the app:
/// that loopback is the machine's, not this Mac's. Found by
/// scripts/cmux-next/proxied-tab-e2e.py (GET /favicon.ico on this Mac's ::1).
@Suite struct AppFetchableFaviconTests {
    @Test func aMachineStoreTabNeverFetchesALoopbackIcon() {
        for text in ["http://localhost:3000/favicon.ico", "http://127.0.0.1:3000/x.png", "http://[::1]:3000/i.ico",
                     "http://app.localhost/favicon.ico"] {
            #expect(!URL(string: text)!.isAppFetchableFavicon(remoteStore: true), "\(text)")
        }
    }

    @Test func otherIconsStillLoad() {
        #expect(URL(string: "https://example.com/favicon.ico")!.isAppFetchableFavicon(remoteStore: true))
        #expect(URL(string: "http://localhost:3000/favicon.ico")!.isAppFetchableFavicon(remoteStore: false))
    }

    @Test func anIconWithoutAHostIsNotFetchedForAMachineStore() {
        #expect(!URL(string: "data:image/png;base64,AAAA")!.isAppFetchableFavicon(remoteStore: true))
    }
}
