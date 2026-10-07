import Foundation
import Testing
@testable import CmuxNextBrowser

/// The app fetches favicons in its own process, which reaches this Mac's
/// localhost. A tab whose store is a remote machine's (a machine store, a
/// Cloud proxied tab) must never have its loopback favicon fetched by the app:
/// that loopback is the machine's, not this Mac's. Found by
/// scripts/cmux-next/proxied-tab-e2e.py (GET /favicon.ico on this Mac's ::1).
@Suite struct BrowserFaviconPolicyTests {
    private let store = BrowserMachineStore(machineKey: "0123456789abcdef", machineName: "api-dev", proxyPort: 49153)

    @Test func aMachineStoreTabNeverFetchesALoopbackIcon() {
        for text in ["http://localhost:3000/favicon.ico", "http://127.0.0.1:3000/x.png", "http://[::1]:3000/i.ico",
                     "http://app.localhost/favicon.ico"] {
            #expect(!BrowserFaviconPolicy.appMayFetch(URL(string: text)!, remoteStore: true), "\(text)")
        }
    }

    @Test func otherIconsStillLoad() {
        #expect(BrowserFaviconPolicy.appMayFetch(URL(string: "https://example.com/favicon.ico")!, remoteStore: true))
        #expect(BrowserFaviconPolicy.appMayFetch(URL(string: "http://localhost:3000/favicon.ico")!, remoteStore: false))
    }

    @Test func aStoreMeansRemote() {
        #expect(BrowserFaviconPolicy.isRemoteStore(store))
        #expect(!BrowserFaviconPolicy.isRemoteStore(nil))
    }
}
