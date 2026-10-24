@testable import CmuxNextHangReports
import Foundation
import Testing

/// A MetricKit frame whose image is not loaded now is ours only by one of our builds' UUIDs,
/// never by a name that looks like ours; the UUIDs of earlier launches are kept.
struct OwnImageUUIDsTests {
    @Test func aNameThatLooksLikeOursWithAnUnknownUUIDIsOther() {
        let classifier = HangReportFixtures.classifier()
        let unknown = "11111111-2222-3333-8444-555555555555"
        #expect(classifier.frame(metricKitName: "Sparkle", uuid: unknown, offset: 8, loaded: nil) == .other)
        #expect(classifier.frame(metricKitName: "cmux-helper", uuid: unknown, offset: 8, loaded: nil) == .other)
        #expect(classifier.frame(metricKitName: HangReportFixtures.appBundle + "/Contents/Frameworks/Evil.framework/Evil",
                                 uuid: unknown, offset: 8, loaded: nil) == .other)
        // One of our builds' UUIDs: named, with its UUID and offset.
        #expect(classifier.frame(metricKitName: "GhosttyKit", uuid: HangReportFixtures.ghosttyUUID, offset: 8, loaded: nil)
            == HangReportFrame(image: "GhosttyKit", uuid: HangReportFixtures.ghosttyUUID, offset: 8))
    }

    @Test func ourImagesFromEarlierLaunchesAreKeptAndOthersAreNot() {
        let suite = "own-uuids-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let bundle = HangReportFixtures.appBundle
        let first = OwnImageUUIDs(appBundlePath: bundle, suiteName: suite, images: { HangReportFixtures.images })
        #expect(first.uuids() == [HangReportFixtures.appUUID])
        // The next build: a new executable UUID; the old one is still ours, AppKit and the plug-in never are.
        let next = LoadedImage(path: bundle + "/Contents/MacOS/cmux NEXT Nightly", uuid: "AAAAAAAA-0000-3000-8000-000000000001",
                               base: 0x1_0000_0000, size: 0x100)
        let second = OwnImageUUIDs(appBundlePath: bundle, suiteName: suite, images: { [next] + HangReportFixtures.images.dropFirst() })
        #expect(second.uuids() == [HangReportFixtures.appUUID, "AAAAAAAA-0000-3000-8000-000000000001"])
    }
}
