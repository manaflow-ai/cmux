@testable import CmuxNextHangReports
import Testing

/// Only images on the sealed system volume (or an OS cryptex) and in the app bundle are named:
/// the Data volume seen through `/System/Volumes/`, firmlinked writable folders and paths with
/// `..` are not Apple's.
struct ImageOwnerTests {
    private let classifier = HangReportFixtures.classifier()
    private let uuid = "0F1E2D3C-4B5A-3968-8776-5A4B3C2D1E0F"

    @Test(arguments: [
        "/System/Volumes/Data/Users/alice/secret-project/libX.dylib",
        "/System/Volumes/Data/Applications/AcmeInternal.app/Contents/MacOS/AcmeInternal",
        "/System/Volumes/Update/mnt1/libAcme.dylib",
        "/System/Library/Caches/com.acme/libAcmeHook.dylib",
        "/System/Library/AssetsV2/com_acme/libAcmeHook.dylib",
        "/usr/lib/../../Users/alice/secret-project/libhook.dylib",
        "/System/Library/Frameworks/../../../Users/alice/libhook.dylib",
        "/System/./Library/libAcme.dylib",
        "/System//Library/libAcme.dylib",
        "System/Library/Frameworks/AppKit.framework/AppKit",
    ])
    func notTheSealedSystemVolume(path: String) {
        #expect(classifier.owner(path: path) == .other)
        let image = LoadedImage(path: path, uuid: uuid, base: 0x3_0000_0000, size: 0x1000)
        #expect(classifier.frame(image: image, offset: 0x10) == .other)
    }

    @Test func aMetricKitPathNameOnTheDataVolumeIsOther() {
        #expect(classifier.frame(metricKitName: "/System/Volumes/Data/Users/alice/secret-project/libX.dylib", uuid: uuid,
                                 offset: 0x10, loaded: nil) == .other)
    }

    @Test(arguments: [
        "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit",
        "/usr/lib/system/libsystem_kernel.dylib",
        "/System/Volumes/Preboot/Cryptexes/OS/System/Library/Frameworks/WebKit.framework/Versions/A/WebKit",
    ])
    func appleImagesStayApples(path: String) {
        #expect(classifier.owner(path: path) == .apple)
    }

    @Test func theAppBundleIsOurs() {
        #expect(classifier.owner(path: HangReportFixtures.appBundle + "/Contents/MacOS/cmux") == .ours)
        #expect(classifier.owner(path: HangReportFixtures.appBundle + "/../Acme.app/Contents/MacOS/Acme") == .other)
    }
}
