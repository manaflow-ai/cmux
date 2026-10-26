@testable import CmuxNextApp
@testable import CmuxNextBrowser
@testable import CmuxNextBrowserImport
@testable import CmuxNextCompat
@testable import CmuxNextServer
import CmuxNextTrace
@testable import CmuxNextUpdater
import CmuxNextWakeups
import Foundation
import Testing

/// p02-threads-122: the static, lazy and global initializers that read a file or asked the kernel or
/// securityd on whichever thread came first are gone. Each value is compiled in, read on a lane and handed
/// over, or read by an async accessor, so the first main-thread access of each records no blocking site.
@Suite("Once initializers: first main access blocks nothing", .serialized)
@MainActor
struct OnceInitializerMainAccessTests {
    static let work = BackgroundWork(label: "test.once-initializers")

    #if DEBUG || CMUX_BLOCKING_CHECKS
    /// The main-thread sites `body` records (each test binds its own table).
    private func mainSites(_ body: () async -> Void) async -> [String] {
        let table = BlockingViolationTable(mode: .record)
        await BlockingViolationTable.$scoped.withValue(table) { await body() }
        await table.flush()
        return table.sites.filter { $0.context == .main }.map(\.location)
    }

    @Test("The top-level domains and the pairing words are compiled in: no file read on main")
    func compiledInLists() async {
        let sites = await mainSites {
            #expect("com".isTopLevelDomain)
            #expect("XN--P1AI".isTopLevelDomain)
            #expect(!"con".isTopLevelDomain)
            #expect(PairingWords.words(thumbprint: String(repeating: "A", count: 43))?.count == 4)
        }
        #expect(sites.isEmpty, "a compiled-in list read a file on the main thread: \(sites)")
    }

    @Test("The browser source registry read on a lane is in memory for the main thread")
    func browserSourceRegistry() async throws {
        let install = BrowserSourceRegistryInstall()
        #expect(!install.isLoaded)
        let rows = try await Self.work.run(.userVisible, mayBlock: .files) { install.registry.browsers.count }
        #expect(install.isLoaded)
        let sites = await mainSites { #expect(install.registry.browsers.count == rows) }
        #expect(sites.isEmpty, "the registry was read again on the main thread: \(sites)")
    }

    @Test("The web update keys are read on the files lane when the first pointer needs them")
    func webUpdateKeys() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "once-keys-\(UUID().uuidString)", directoryHint: .isDirectory)
        let updater = WebUpdater(store: WebUpdateStore(base: root), app: .init(abi: 2, webBuiltAt: 1_700_000_000),
                                 keys: .bundled(Self.work))
        var keys: WebUpdateKeys?
        let sites = await mainSites { keys = try? await updater.trustedKeys() }
        #expect(sites.isEmpty, "the bundled keys were read on the main thread: \(sites)")
        #expect(keys?.keys.isEmpty == false)
    }

    @Test("The Settings page's sounds are listed on the files lane")
    func settingsSounds() async {
        var sounds: [String] = []
        let sites = await mainSites { sounds = await SettingsPageDomains.sounds(work: Self.work) }
        #expect(sites.isEmpty, "the sounds folder was listed on the main thread: \(sites)")
        #expect(sounds == sounds.sorted())
    }

    @Test("The browser export steps are read on the files lane")
    func browserExportSteps() async throws {
        var rows: [BrowserExportSource] = []
        let sites = await mainSites {
            rows = (try? await Self.work.run(.userBlocking, mayBlock: .files) { BrowserExportSource.loadBundled() }) ?? []
        }
        #expect(sites.isEmpty, "the export steps were read on the main thread: \(sites)")
        #expect(!rows.isEmpty)
    }
    #endif

    @Test("The pairing words are the BIP-39 English list, in index order")
    func pairingWordsList() {
        #expect(PairingWords.list.count == 2048)
        #expect(PairingWords.list.first == "abandon")
        #expect(PairingWords.list.last == "zoo")
    }

    @Test("Chromium's ready time counts from the kernel's process start on the launch clock")
    func secondsSinceLaunch() {
        let clock = LaunchClock(reader: .init(processStartWallNanos: { 10_000_000_000 }, wallNanos: { 12_500_000_000 },
                                              uptimeNanos: { 40_000_000_000 }, pageins: { nil }))
        #expect(CEFStartReport.secondsSinceLaunch(clock) == 2.5)
        let noKernel = LaunchClock(reader: .init(processStartWallNanos: { nil }, wallNanos: { 0 }, uptimeNanos: { 0 }, pageins: { nil }))
        #expect(CEFStartReport.secondsSinceLaunch(noKernel) == nil)
    }
}
