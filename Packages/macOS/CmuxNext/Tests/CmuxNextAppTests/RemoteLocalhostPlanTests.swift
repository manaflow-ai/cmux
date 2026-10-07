import CmuxNextBrowser
import Foundation
import Testing
@testable import CmuxNextApp

/// Which store and navigation guard a Chromium page gets
/// (plans/cmux-next/remote-localhost.md section 3).
struct RemoteLocalhostPlanTests {
    let localhost = URL(string: "http://localhost:5173/")!
    let github = URL(string: "https://github.com/manaflow-ai/cmux")!

    @Test func aRemoteMachinesLoopbackPageGetsTheDerivedStore() {
        #expect(RemoteLocalhostStorePlan.plan(route: .machine("build-box"), url: localhost) == .derived)
        #expect(RemoteLocalhostStorePlan.plan(route: .machine("build-box"), url: URL(string: "http://127.0.0.1:3000/")!) == .derived)
    }

    @Test func otherPagesOfARemoteTabKeepTheProfileStoreAndRefuseLoopback() {
        #expect(RemoteLocalhostStorePlan.plan(route: .machine("build-box"), url: github) == .profile(.noLoopback))
        #expect(RemoteLocalhostStorePlan.plan(route: .machine("build-box"), url: nil) == .profile(.noLoopback))
        // A public name that resolves to loopback is not a loopback URL.
        #expect(RemoteLocalhostStorePlan.plan(route: .machine("build-box"), url: URL(string: "http://127.0.0.1.nip.io/")!)
            == .profile(.noLoopback))
    }

    @Test func thisMacAndDeliberateFallbacksAreUnrestricted() {
        #expect(RemoteLocalhostStorePlan.plan(route: .thisMac, url: localhost) == .profile(.none))
        for reason in [RemoteLocalhostFallback.updateMachine, .turnedOff, .webKit] {
            #expect(RemoteLocalhostStorePlan.plan(route: .thisMacInstead("build-box", reason), url: localhost) == .profile(.none))
        }
    }

    @Test func machineKeysAreStableHexAndDistinct() {
        let key = RemoteLocalhostService.machineKey(registryID: "7d3c1e0a-0000-4000-8000-000000000001")
        #expect(key.count == 16)
        #expect(key.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        #expect(key == RemoteLocalhostService.machineKey(registryID: "7d3c1e0a-0000-4000-8000-000000000001"))
        #expect(key != RemoteLocalhostService.machineKey(registryID: "7d3c1e0a-0000-4000-8000-000000000002"))
    }

    @Test func derivedStoresAreSiblingsOfTheProfileDirectory() {
        let storage = CEFProfileStorage(root: URL(filePath: "/tmp/Chromium"))
        let profile = BrowserProfileID.default
        let derived = storage.cachePath(for: profile, machineKey: "0123456789abcdef")
        #expect(derived.deletingLastPathComponent().standardizedFileURL.path == storage.root.standardizedFileURL.path)
        #expect(derived.lastPathComponent == "Profile-\(profile.rawValue.uuidString)-m-0123456789abcdef")
        #expect(storage.cachePath(for: profile, machineKey: nil) == storage.cachePath(for: profile))
        #expect(storage.cachePath(for: profile, machineKey: "../evil") == storage.cachePath(for: profile))
    }
}
