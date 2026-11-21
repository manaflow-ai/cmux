import AppKit
import CmuxNextTestSupport
import CmuxNextWakeups
import Foundation
import Testing

/// One fleet receipt renders all affected surfaces and retains them in one artifact.
@MainActor @Suite(.serialized, .closesItsWindows)
struct AAScreenSharingGalleryTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderAllSurfaces() async throws {
        try AAMacScreenSetupGalleryTests().renderGallery()
        try AAMacScreenSharingBarGalleryTests().renderGallery()
        try AASidebarScreenActionsGalleryTests().renderGallery()
        let request = ProcessRequest(URL(fileURLWithPath: "/usr/bin/tar"),
                                     ["cf", "screen-sharing-native-gallery.tar", "mac-screen-setup-gallery",
                                      "mac-screen-sharing-bar-gallery", "sidebar-screen-actions-gallery"],
                                     directory: AANestedGroupsGalleryTests.packageRoot, timeout: .seconds(30))
        let result = try await AsyncProcess().run(request)
        #expect(result.succeeded)
    }
}
