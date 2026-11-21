import Foundation
import Testing
@testable import CmuxMobileModel

/// A dev build's own Cloud backend (`CMUX_NEXT_CLOUD_BACKEND`, `review.sh --backend`): which values are
/// allowed, the order the sources win in, that it is kept for later launches, and that a build
/// without DEBUG reads only its Info.plist.
@Suite struct CloudBackendOverrideTests {
    let stack = "https://cmux-dev-backend-1.tail137216.ts.net:3850"
    let build = "https://cloud-api-staging.cmux.dev"

    func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "CloudBackendOverrideTests.\(UUID().uuidString)"))
    }

    func service(_ env: [String: String], _ defaults: UserDefaults, debug: Bool = true) -> CloudBackendOverride? {
        CloudBackendOverride.cloudService(environment: env, infoValue: build, defaults: defaults, debug: debug)
    }

    @Test func onlyTheSharedDevDeploymentAndTailnetOriginsAreAllowed() {
        #expect(CloudBackendOverride.allowed("dev")?.absoluteString == "https://cmux-api-development.debussy.workers.dev")
        #expect(CloudBackendOverride.allowed("https://cmux-api-development.debussy.workers.dev/")?.absoluteString
            == "https://cmux-api-development.debussy.workers.dev")
        #expect(CloudBackendOverride.allowed("preview-12")?.absoluteString == "https://cmux-api-preview-12.debussy.workers.dev")
        #expect(CloudBackendOverride.allowed("https://cmux-api-preview-12.debussy.workers.dev")?.absoluteString
            == "https://cmux-api-preview-12.debussy.workers.dev")
        #expect(CloudBackendOverride.allowed(stack)?.absoluteString == stack)
        #expect(CloudBackendOverride.allowed("https://cmux-dev-backend-1.tail137216.ts.net")?.absoluteString
            == "https://cmux-dev-backend-1.tail137216.ts.net")
        for refused in [
            "https://attacker.example",
            "https://cloud-api.cmux.dev",
            "prod",
            "http://cmux-dev-backend-1.tail137216.ts.net:3850",
            "https://ts.net",
            "https://tail137216.ts.net",
            "https://cmux-dev-backend-1.tail137216.ts.net.attacker.example",
            "https://cmux-dev-backend-1.tail137216.ts.net/v1",
            "https://cmux-dev-backend-1.tail137216.ts.net?x=1",
            "https://user@cmux-dev-backend-1.tail137216.ts.net",
            "https://cmux_dev.tail137216.ts.net",
            // Another tailnet's machine (a Funnel name is public) or a name under ours that is no machine.
            "https://cmux-dev-backend-1.tail9999.ts.net:3850",
            "https://evil.ts.net",
            "https://a.b.tail137216.ts.net",
            // Under cmux.dev but no tag stack's API host.
            "https://mobile.s7.wdev.cmux.dev",
            "https://api.s7.wdev.cmux.dev:8443",
            "https://api.s7.other.cmux.dev",
            "https://cmux.dev",
            "https://cmux-api-development.debussy.workers.dev:444",
            "preview-0",
            "preview-x",
            "https://100.70.231.80",
        ] {
            #expect(CloudBackendOverride.allowed(refused) == nil, "\(refused)")
        }
    }

    @Test func theLaunchWinsThenTheRigThenTheKeptOneThenTheBuild() throws {
        let defaults = try defaults()
        #expect(service([:], defaults) == CloudBackendOverride(url: URL(string: build)!, source: .build))
        let launched = service(["CMUX_NEXT_CLOUD_BACKEND": stack, "CMUX_MOBILE_CLOUD_API_BASE": "https://rig.invalid"], defaults)
        #expect(launched == CloudBackendOverride(url: URL(string: stack)!, source: .launch))
        // The rig's variable beats the kept override, which was still recorded above.
        #expect(service(["CMUX_MOBILE_CLOUD_API_BASE": "https://rig.invalid"], defaults)?.source == .rig)
        // A launch with no variables (a tap on the icon) keeps the hand-off's backend.
        #expect(service([:], defaults) == CloudBackendOverride(url: URL(string: stack)!, source: .stored))
        #expect(service([:], defaults)?.label == "cmux-dev-backend-1.tail137216.ts.net:3850 (stored)")
    }

    @Test func anEmptyValueClearsAndARefusedValueChangesNothing() throws {
        let defaults = try defaults()
        _ = service(["CMUX_NEXT_CLOUD_BACKEND": stack], defaults)
        let refused = service(["CMUX_NEXT_CLOUD_BACKEND": "https://attacker.example"], defaults)
        #expect(refused == CloudBackendOverride(url: URL(string: stack)!, source: .stored))
        #expect(defaults.string(forKey: CloudBackendOverride.storedKey) == stack)
        #expect(service(["CMUX_NEXT_CLOUD_BACKEND": ""], defaults)?.source == .build)
        #expect(defaults.string(forKey: CloudBackendOverride.storedKey) == nil)
        _ = service(["CMUX_NEXT_CLOUD_BACKEND": stack], defaults)
        #expect(service(["CMUX_NEXT_CLOUD_BACKEND": "default"], defaults)?.source == .build)
    }

    /// A tag's stack serves its API, mobile Worker and device hub on three consecutive ports of one tailnet
    /// host (scripts/cmux-next/cloud-dev-stack.sh), so the one API origin the hand-off passes names all three.
    /// The shared development deployment and previews keep the build's own services.
    @Test func aTagStackNamesItsOwnMobileWorkerAndHubOnTheNextPorts() throws {
        let defaults = try defaults()
        let chosen = try #require(service(["CMUX_NEXT_CLOUD_BACKEND": stack], defaults))
        #expect(chosen.mobileAPI?.absoluteString == "https://cmux-dev-backend-1.tail137216.ts.net:3851")
        #expect(chosen.deviceHub?.absoluteString == "https://cmux-dev-backend-1.tail137216.ts.net:3852")
        // Kept for a plain relaunch (no launch variables), with the same services.
        let kept = try #require(CloudBackendOverride.resolve(environment: [:], defaults: defaults))
        #expect(kept.mobileAPI == chosen.mobileAPI && kept.deviceHub == chosen.deviceHub)
        for shared in ["dev", "preview-12", "https://cmux-dev-backend-1.tail137216.ts.net"] {
            let other = try #require(CloudBackendOverride.allowed(shared))
            let override = CloudBackendOverride(url: other, source: .launch)
            #expect(override.mobileAPI == nil && override.deviceHub == nil, "\(shared) keeps the build's own services")
        }
        #expect(CloudBackendOverride(url: URL(string: build)!, source: .build).mobileAPI == nil)
    }

    /// A tag stack's public origin (the authenticating gateway, for a phone off the tailnet): one slot's
    /// `api.` host, whose `mobile.` and `hub.` siblings are its other services. Nothing else under
    /// wdev.cmux.dev is a backend.
    @Test func aTagStacksPublicOriginIsAllowedWithItsOwnSlotsServices() throws {
        let publicStack = "https://api.s7.wdev.cmux.dev"
        #expect(CloudBackendOverride.allowed(publicStack)?.absoluteString == publicStack)
        #expect(CloudBackendOverride.allowed("https://API.s7.wdev.cmux.dev/")?.absoluteString == publicStack)
        for refused in ["http://api.s7.wdev.cmux.dev", "https://api.s7.wdev.cmux.dev:8443", "https://mobile.s7.wdev.cmux.dev",
                        "https://api.s7777.wdev.cmux.dev", "https://api.x7.wdev.cmux.dev", "https://api.s7.wdev.cmux.dev.attacker.example",
                        "https://a.api.s7.wdev.cmux.dev", "https://wdev.cmux.dev", "https://api.s7.wdev.cmux.dev/v1"] {
            #expect(CloudBackendOverride.allowed(refused) == nil, "\(refused)")
        }
        let chosen = try #require(CloudBackendOverride.resolve(environment: ["CMUX_NEXT_CLOUD_BACKEND": publicStack], defaults: defaults()))
        #expect(chosen.mobileAPI?.absoluteString == "https://mobile.s7.wdev.cmux.dev")
        #expect(chosen.deviceHub?.absoluteString == "https://hub.s7.wdev.cmux.dev")
    }

    /// Release, TestFlight and App Store builds (no DEBUG) read only Info.plist: no launch value, no
    /// kept value, no rig value, and they store nothing.
    @Test func aBuildWithoutDebugIgnoresEveryOverride() throws {
        let defaults = try defaults()
        defaults.set(stack, forKey: CloudBackendOverride.storedKey)
        let release = service(["CMUX_NEXT_CLOUD_BACKEND": "dev", "CMUX_MOBILE_CLOUD_API_BASE": "https://rig.invalid"],
                              defaults, debug: false)
        #expect(release == CloudBackendOverride(url: URL(string: build)!, source: .build))
        #expect(defaults.string(forKey: CloudBackendOverride.storedKey) == stack, "a non-DEBUG build writes nothing")
        #expect(DeveloperOptions.storedKeys.contains(CloudBackendOverride.storedKey), "Production removes the kept value")
    }
}
