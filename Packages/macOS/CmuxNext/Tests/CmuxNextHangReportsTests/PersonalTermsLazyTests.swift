@testable import CmuxNextHangReports
import CmuxNextCompat
import Foundation
import Testing

/// The personal terms (NSFullUserName: an OpenDirectory lookup) are read at the first name check
/// or scan, never when the classifier and the scanner are made: the app makes them on the main
/// thread at launch, also when reports are off.
struct PersonalTermsLazyTests {
    final class Reads: Sendable {
        private let count = Mutex(0)
        func terms() -> [String] {
            count.withLock { $0 += 1 }
            return ["alice"]
        }
        var value: Int { count.withLock { $0 } }
    }

    @Test func makingTheClassifierAndTheScannerReadsNoTerms() {
        let reads = Reads()
        let classifier = ImageClassifier(appBundlePath: nil, forbiddenTerms: reads.terms(), systemImageExists: { _ in true })
        let scanner = PrivacyLeakScanner(forbiddenTerms: reads.terms())
        let builder = HangReportBuilder(classifier: classifier, resolver: HangReportFixtures.FakeResolver(images: [
            LoadedImage(path: "/usr/lib/libalice.dylib", uuid: HangReportFixtures.imeUUID, base: 0x1000, size: 0x1000),
            LoadedImage(path: "/usr/lib/libdispatch.dylib", uuid: HangReportFixtures.appKitUUID, base: 0x4000, size: 0x1000),
        ]))
        #expect(reads.value == 0)
        #expect(builder.frames(addresses: [0x1010, 0x4010]).map(\.image) == [HangReportFrame.otherImage, "libdispatch.dylib"])
        #expect(!scanner.findings(in: Data(#"{"name":"alice"}"#.utf8)).isEmpty)
        #expect(reads.value > 0)
    }
}
