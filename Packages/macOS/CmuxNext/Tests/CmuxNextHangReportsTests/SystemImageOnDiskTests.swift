@testable import CmuxNextHangReports
import Testing

/// A MetricKit frame whose image is no longer loaded is named only when the name is Apple's. Since
/// macOS 11 the system dylibs live only in the dyld shared cache, not on disk, so the check must
/// look there too (macOS 14, 15, 26 and 27 all ship them that way).
struct SystemImageOnDiskTests {
    @Test(arguments: ["libdispatch.dylib", "libsystem_kernel.dylib", "libobjc.A.dylib", "libSystem.B.dylib"])
    func aSharedCacheDylibIsApples(name: String) {
        #expect(ImageClassifier.systemImageOnDisk(name))
    }

    @Test(arguments: ["AppKit", "Foundation"])
    func aSystemFrameworkIsApples(name: String) {
        #expect(ImageClassifier.systemImageOnDisk(name))
    }

    @Test(arguments: ["libAcmeHook-not-a-system-library.dylib", "", ".hidden", "system/libdispatch.dylib", "../libX.dylib"])
    func anyOtherNameIsNot(name: String) {
        #expect(!ImageClassifier.systemImageOnDisk(name))
    }
}
