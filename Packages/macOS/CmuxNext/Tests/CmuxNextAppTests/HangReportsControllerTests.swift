@testable import CmuxNextApp
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextHangReports
import CmuxNextSettings
import CmuxNextSidebar
import Foundation
import Testing

/// The controller's own wiring, with a real SettingsController on a scratch file, a real service
/// and a recording transport: Not Now on the invitation sends nothing and records no consent;
/// reports turned off remove the consent and stop the service; a managed `DisableTelemetry` at
/// launch runs the off path (queued reports and the install id go) and asks nothing.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct HangReportsControllerTests {
    final class RecordingTransport: HangReportTransport {
        let bodies = Mutex<[Data]>([])
        func send(_ body: Data) async -> HangReportTransportResult {
            bodies.withLock { $0.append(body) }
            return .retryLater
        }
        var count: Int { bodies.withLock { $0.count } }
    }

    struct Harness {
        let suite: String
        let defaults: UserDefaults
        let home: URL
        let settings: SettingsController
        let service: HangReportService
        let transport: RecordingTransport
        let asks: SidebarAsks
        let controller: HangReportsController

        func cleanUp() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: home)
        }
    }

    private func harness(file: String = "{}", managedDisables: Bool = false,
                         prepare: (UserDefaults) -> Void = { _ in }) async throws -> Harness {
        let suite = "cn-hang-controller-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        prepare(defaults)
        let home = FileManager.default.temporaryDirectory.appending(path: suite)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let url = home.appending(path: "cmux-next.json")
        try Data(file.utf8).write(to: url)
        let settings = SettingsController(registry: .standard(), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        let transport = RecordingTransport()
        let collector = HangReportCollector(resolve: { _ in [.other] }, imageRemovedSince: { _ in false }, schedule: { $0() })
        let service = HangReportService(
            store: HangReportStore(directory: home.appending(path: "HangReports")), transport: transport,
            builder: HangReportBuilder(classifier: ImageClassifier(appBundlePath: nil, forbiddenTerms: []), resolver: DyldImageResolver()),
            scanner: PrivacyLeakScanner(forbiddenTerms: []), identity: InstallIdentity(suiteName: suite), collector: collector,
            environment: HangReportService.Environment(
                app: HangReport.App(version: "0.70.0", build: "70123", channel: "nightly"), os: HangReport.OS(version: "15.7.4"),
                hardware: HardwareClass(arch: "arm64", chip: "Apple M4 Pro", cores: 14, memoryGB: 48), counts: { .unknown },
                stillAllowed: { [suite, key = HangReportsController.consentKey] in
                    !managedDisables && UserDefaults(suiteName: suite)?.object(forKey: key) is Date
                }))
        let controller = HangReportsController(service: service, managedDisables: { managedDisables }, defaults: defaults)
        let asks = SidebarAsks()
        controller.start(settings: settings, asks: asks, firstWindow: {})
        return Harness(suite: suite, defaults: defaults, home: home, settings: settings, service: service, transport: transport,
                       asks: asks, controller: controller)
    }

    /// Waits for `condition` on the main actor, a turn at a time (test-only; the suite has a time limit).
    private func until(_ condition: @MainActor () async -> Bool) async {
        while !(await condition()) { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func notNowOnTheInvitationSendsNothingAndRecordsNoConsent() async throws {
        let h = try await harness()
        defer { h.cleanUp() }
        await until { h.asks.card != nil }
        let card = try #require(h.asks.card)
        #expect(h.asks.answer(card.id, action: "no"))
        await until { h.defaults.bool(forKey: HangReportsController.askedKey) }
        #expect(h.defaults.object(forKey: HangReportsController.consentKey) == nil)
        #expect(h.settings.snapshot.hangReports == false)
        #expect(await h.service.isEnabled == false)
        #expect(h.transport.count == 0)
    }

    @Test func noInvitationWhenAnonymousTelemetryIsOff() async throws {
        let h = try await harness { $0.set(false, forKey: "sendAnonymousTelemetry") }
        defer { h.cleanUp() }
        // The observation ran once (the service settled off); no card came.
        await until { await h.service.isEnabled == false }
        for _ in 0..<20 { await Task.yield() }
        #expect(h.asks.card == nil)
    }

    @Test func turningReportsOffRemovesTheConsentAndStopsSending() async throws {
        let h = try await harness(file: #"{"diagnostics": {"hangReports": true}}"#) {
            $0.set(Date(timeIntervalSinceNow: -60), forKey: HangReportsController.consentKey)
        }
        defer { h.cleanUp() }
        await until { await h.service.isEnabled }
        try await h.settings.setSetting(at: HangReportsSetting.path, to: .bool(false), by: .user)
        await until { await h.service.isEnabled == false }
        #expect(h.defaults.object(forKey: HangReportsController.consentKey) == nil)
        #expect(h.asks.card == nil, "off is the person's answer; nothing asks again")
    }

    @Test func aSyncedFileWithoutConsentShowsTheConfirmCardAndSendsNothing() async throws {
        let h = try await harness(file: #"{"diagnostics": {"hangReports": true}}"#)
        defer { h.cleanUp() }
        await until { h.asks.card != nil }
        #expect(await h.service.isEnabled == false)
        #expect(h.transport.count == 0)
        let card = try #require(h.asks.card)
        #expect(h.asks.answer(card.id, action: "yes"))
        await until { await h.service.isEnabled }
        #expect(h.defaults.object(forKey: HangReportsController.consentKey) is Date)
        try await h.settings.setSetting(at: HangReportsSetting.path, to: .bool(false), by: .user)
        await until { await h.service.isEnabled == false }
    }

    @Test func aManagedBlockAtLaunchRunsTheOffPathAndAsksNothing() async throws {
        let h = try await harness(file: #"{"diagnostics": {"hangReports": true}}"#, managedDisables: true) {
            $0.set(Date(timeIntervalSinceNow: -60), forKey: HangReportsController.consentKey)
            $0.set("0b8d4a51-6c9e-4f0f-8f53-3c2d7b4f9e20", forKey: InstallIdentity.idKey)
            $0.set(Date(), forKey: InstallIdentity.createdKey)
        }
        defer { h.cleanUp() }
        await until { h.defaults.string(forKey: InstallIdentity.idKey) == nil }
        #expect(await h.service.isEnabled == false)
        #expect(h.asks.card == nil)
        #expect(h.transport.count == 0)
    }
}
