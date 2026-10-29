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
        let classifier = ImageClassifier(appBundlePath: nil, forbiddenTerms: reads.terms())
        let scanner = PrivacyLeakScanner(forbiddenTerms: reads.terms())
        #expect(reads.value == 0)
        #expect(classifier.sendableName("/usr/lib/libalice.dylib") == nil)
        #expect(classifier.sendableName("/usr/lib/libdispatch.dylib") == "libdispatch.dylib")
        #expect(!scanner.findings(in: Data(#"{"name":"alice"}"#.utf8)).isEmpty)
        #expect(reads.value > 0)
    }
}
