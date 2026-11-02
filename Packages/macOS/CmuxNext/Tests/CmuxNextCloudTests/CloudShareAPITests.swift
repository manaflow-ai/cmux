import CmuxNextCloud
import Foundation
import Testing

/// A guest link's owner token comes from the API of the room the daemon makes the link in
/// (cmux-tui share_room.rs): a DEV build's room is development's, and its owner API is the development Worker too.
@Suite
struct CloudShareAPITests {
    @Test func aDebugBuildMintsShareTokensFromTheDevelopmentWorker() {
        let configuration = CloudConfiguration.resolve(bundleID: "com.cmuxterm.app.debug.walk", bundled: [:], process: [:], isDebugBuild: true)
        #expect(configuration.ownerAPIBaseURL(environment: [:]).absoluteString == "https://cmux-api-development.debussy.workers.dev")
        #expect(configuration.shareAPIBaseURL(environment: [:]).absoluteString == "https://cmux-api-development.debussy.workers.dev")
    }

    @Test func anOwnerAPIOverrideIsTheShareAPITooAndAReleaseBuildKeepsItsOwnerAPI() {
        let debug = CloudConfiguration.resolve(bundleID: "com.cmuxterm.app.debug.walk", bundled: [:], process: [:], isDebugBuild: true)
        let named = ["CMUX_NEXT_FEED_API_URL": "https://owner.standin.invalid"]
        #expect(debug.shareAPIBaseURL(environment: named) == debug.ownerAPIBaseURL(environment: named))
        let release = CloudConfiguration.resolve(bundleID: "com.cmuxterm.app", bundled: [:], process: [:], isDebugBuild: false)
        #expect(release.shareAPIBaseURL(environment: [:]) == release.ownerAPIBaseURL(environment: [:]))
    }
}

/// cmux#31372: the owner token comes from the API the daemon's room names, not from the build kind; each
/// API gets its own install, found again by a later launch so a sign-out still revokes it.
@Suite
struct ShareInstallsTests {
    static let development = URL(string: "https://cmux-api-development.debussy.workers.dev")!
    static let staging = URL(string: "https://cloud-api-staging.cmux.dev")!
    static let production = URL(string: "https://cloud-api.cmux.dev")!

    static func identity(_ root: URL, _ folder: String) -> MacInstallIdentity {
        MacInstallIdentity(store: .files(directory: root.appendingPathComponent(folder)),
                           transport: InstallHTTPTransport(baseURL: development), deviceName: "Test Mac", clientVersion: nil)
    }

    static func installs(_ root: URL, owner: MacInstallIdentity, fallback: MacInstallIdentity, release: Bool = false) -> ShareInstalls {
        let configuration = CloudConfiguration.resolve(bundleID: release ? "com.cmuxterm.app" : "com.cmuxterm.app.debug.walk", bundled: [:],
                                                       process: [:], isDebugBuild: !release)
        return ShareInstalls(root: root, given: [(production, owner), (development, fallback)], fallback: fallback,
                             accepts: { configuration.acceptsShareAPI($0) }, make: { _, folder in identity(root, folder) })
    }

    @Test func theRoomsAPIPicksTheInstallAndALaterLaunchFindsIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("share-installs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = Self.identity(root, "install"), fallback = Self.identity(root, "install-share")
        let installs = Self.installs(root, owner: owner, fallback: fallback)
        #expect(await installs.identity(for: nil) === fallback)
        #expect(await installs.identity(for: Self.development) === fallback)
        #expect(await installs.identity(for: Self.production) === owner)
        #expect(await installs.identity(for: URL(string: "https://cmux-api-other.invalid:8443")) === fallback, "no port: one install per host")
        let staging = await installs.identity(for: Self.staging)
        #expect(staging !== fallback && staging !== owner)
        #expect(await installs.identity(for: Self.staging) === staging)
        #expect(await installs.identity(for: URL(string: "http://cloud-api-staging.cmux.dev")) === fallback)
        await installs.began(switched: true, except: owner)
        #expect(await installs.identity(for: Self.staging) === staging, "a switch unbinds the install and keeps it")
        // After a sign-out listed them, a share racing it makes no install the sign-out missed.
        let all = await installs.ended(except: owner)
        #expect(all.count == 2 && all.contains { $0 === staging } && all.contains { $0 === fallback })
        #expect(await installs.identity(for: URL(string: "https://cmux-api-other.invalid")) === fallback)
        #expect(await installs.identity(for: Self.staging) === staging)
        await installs.began(switched: false, except: owner)
        #expect(await installs.identity(for: URL(string: "https://cmux-api-other.invalid")) !== fallback)

        try FileManager.default.createDirectory(at: root.appendingPathComponent("install-share-cloud-api-staging.cmux.dev"),
                                                withIntermediateDirectories: true)
        let relaunched = Self.installs(root, owner: owner, fallback: fallback)
        #expect(await relaunched.ended(except: owner).count == 2, "a sign-out after a relaunch reaches the staging install")
    }

    @Test func aReleaseBuildSendsCredentialsOnlyToACmuxAPI() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("share-installs-\(UUID().uuidString)")
        let owner = Self.identity(root, "install"), fallback = Self.identity(root, "install-share")
        let installs = Self.installs(root, owner: owner, fallback: fallback, release: true)
        #expect(await installs.identity(for: URL(string: "https://elsewhere.invalid")) === fallback)
        #expect(await installs.identity(for: Self.staging) !== fallback)
        #expect(await installs.identity(for: URL(string: "https://cloud-api.cmux.dev:8443")) === fallback, "another origin of a cmux host")
        #expect(await installs.identity(for: URL(string: "https://cloud-api-staging.cmux.dev/v1?x=1")) === fallback, "only a bare origin")
        let debug = Self.installs(root, owner: owner, fallback: fallback)
        #expect(await debug.identity(for: URL(string: "https://elsewhere.invalid")) !== fallback)
    }
}
