@testable import CmuxNextHangReports
import Foundation
import Testing

/// Only images on the sealed system volume (or an OS cryptex) and in the app bundle are named:
/// the Data volume seen through `/System/Volumes/`, firmlinked writable folders and paths with
/// `..` are not Apple's.
struct ImageOwnerTests {
    private let uuid = "0F1E2D3C-4B5A-3968-8776-5A4B3C2D1E0F"

    /// The frame of an address inside an image loaded from `path`.
    private func frame(path: String) -> HangReportFrame? {
        let image = LoadedImage(path: path, uuid: uuid, base: 0x3_0000_0000, size: 0x1000)
        let builder = HangReportBuilder(classifier: HangReportFixtures.classifier(),
                                        resolver: HangReportFixtures.FakeResolver(images: [image]))
        return builder.frames(addresses: [0x3_0000_0010]).first
    }

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
        #expect(frame(path: path) == .other)
    }

    @Test(arguments: [
        "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit",
        "/usr/lib/system/libsystem_kernel.dylib",
        "/System/Volumes/Preboot/Cryptexes/OS/System/Library/Frameworks/WebKit.framework/Versions/A/WebKit",
    ])
    func appleImagesStayApples(path: String) {
        #expect(frame(path: path) == HangReportFrame(image: (path as NSString).lastPathComponent, uuid: uuid, offset: 0x10))
    }

    @Test func theAppBundleIsOurs() {
        #expect(frame(path: HangReportFixtures.appBundle + "/Contents/MacOS/cmux")?.image == "cmux")
        #expect(frame(path: HangReportFixtures.appBundle + "/../Acme.app/Contents/MacOS/Acme") == .other)
    }
}
