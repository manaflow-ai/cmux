import Foundation
import Testing
@preconcurrency import Sparkle
@testable import CmuxUpdater

private struct ImmediateUpdateClock: UpdateClock {
    func sleep(for _: Duration) async throws {}
}

@MainActor
@Suite struct UpdateOutcomeContractTests {
    private func makeItem(
        _ version: String = "0.64.20",
        minimumSystemVersion: String? = nil,
        maximumSystemVersion: String? = nil
    ) -> SUAppcastItem {
        var dictionary: [String: Any] = [
            "title": "cmux \(version)",
            "pubDate": "Wed, 25 Mar 2026 12:00:00 +0000",
            "enclosure": [
                "url": "https://example.com/cmux.zip",
                "length": "1024",
                "sparkle:version": "100",
                "sparkle:shortVersionString": version,
            ],
        ]
        dictionary["sparkle:minimumSystemVersion"] = minimumSystemVersion
        dictionary["sparkle:maximumSystemVersion"] = maximumSystemVersion
        return SUAppcastItem(dictionary: dictionary) ?? SUAppcastItem.empty()
    }

    private func noUpdateError(
        reason: SPUNoUpdateFoundReason,
        latestItem: SUAppcastItem? = nil
    ) -> NSError {
        var userInfo: [String: Any] = [
            SPUNoUpdateFoundReasonKey: NSNumber(value: reason.rawValue),
            SPUNoUpdateFoundUserInitiatedKey: true,
        ]
        userInfo[SPULatestAppcastItemFoundKey] = latestItem
        return NSError(domain: SUSparkleErrorDomain, code: 1001, userInfo: userInfo)
    }

    private func presentation(
        for reason: SPUNoUpdateFoundReason,
        latestItem: SUAppcastItem? = nil
    ) -> (title: String, message: String) {
        let model = UpdateStateModel()
        let driver = UpdateDriver(
            model: model,
            log: NoopUpdateLog(),
            clock: ImmediateUpdateClock()
        )
        driver.showUpdateNotFoundWithError(
            noUpdateError(reason: reason, latestItem: latestItem),
            acknowledgement: {}
        )
        return (model.text, model.description)
    }

    /// A local UI deadline is not evidence that the feed contains no newer version. A slow
    /// Sparkle request must remain in progress until Sparkle returns an authoritative result.
    @Test func slowCheckNeverClaimsTheInstalledBuildIsLatest() async {
        let model = UpdateStateModel()
        let driver = UpdateDriver(
            model: model,
            log: NoopUpdateLog(),
            clock: ImmediateUpdateClock()
        )

        driver.showUserInitiatedUpdateCheck(cancellation: {})
        for _ in 0..<100 { await Task.yield() }

        guard case .checking = model.state else {
            Issue.record("slow check produced a false terminal: \(model.state)")
            return
        }
        #expect(!model.description.localizedCaseInsensitiveContains("latest"))
    }

    @Test func authoritativeLatestResultUsesUpToDateCopy() {
        let result = presentation(for: .onLatestVersion, latestItem: makeItem())
        #expect(result.title.localizedCaseInsensitiveContains("no updates"))
        #expect(result.message.localizedCaseInsensitiveContains("latest"))
    }

    @Test func newerThanFeedResultSaysTheInstalledBuildIsNewer() {
        let result = presentation(for: .onNewerThanLatestVersion, latestItem: makeItem())
        #expect(result.message.localizedCaseInsensitiveContains("newer"))
    }

    @Test func oldSystemResultNamesTheAvailableVersionAndRequirement() {
        let result = presentation(
            for: .systemIsTooOld,
            latestItem: makeItem(minimumSystemVersion: "15.0")
        )
        #expect(result.message.contains("0.64.20"))
        #expect(result.message.contains("15.0"))
        #expect(result.message.localizedCaseInsensitiveContains("macOS"))
        #expect(!result.message.localizedCaseInsensitiveContains("running the latest"))
    }

    @Test func newSystemResultNamesTheAvailableVersionAndMaximum() {
        let result = presentation(
            for: .systemIsTooNew,
            latestItem: makeItem(maximumSystemVersion: "26.0")
        )
        #expect(result.message.contains("0.64.20"))
        #expect(result.message.contains("26.0"))
        #expect(!result.message.localizedCaseInsensitiveContains("running the latest"))
    }

    @Test func unsupportedHardwareResultNamesAppleSiliconRequirement() {
        let result = presentation(for: .hardwareDoesNotSupportARM64, latestItem: makeItem())
        #expect(result.message.contains("0.64.20"))
        #expect(result.message.localizedCaseInsensitiveContains("Apple silicon"))
        #expect(!result.message.localizedCaseInsensitiveContains("running the latest"))
    }

    @Test func unknownNoUpdateReasonDoesNotClaimTheInstalledBuildIsLatest() {
        let result = presentation(for: .unknown, latestItem: makeItem())
        #expect(!result.message.localizedCaseInsensitiveContains("running the latest"))
    }

    @Test func actionableNoUpdateReasonsStayVisibleUntilAcknowledged() {
        let reasons: [UpdateState.NotFound.Reason] = [
            .systemTooOld(latestVersion: "0.64.20", minimumSystemVersion: "15.0"),
            .systemTooNew(latestVersion: "0.64.20", maximumSystemVersion: "26.0"),
            .unsupportedHardware(latestVersion: "0.64.20"),
            .developmentBuild,
            .unknown,
        ]

        #expect(reasons.allSatisfy {
            !UpdateState.NotFound(reason: $0, acknowledgement: {}).automaticallyDismisses
        })
        #expect(UpdateState.NotFound(reason: .upToDate, acknowledgement: {}).automaticallyDismisses)
    }
}
