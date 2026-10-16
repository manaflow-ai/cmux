import Foundation
import Testing
@testable import CmuxCEF

@Suite("Chromium native-messaging host folders")
struct CEFNativeMessagingTests {
    @Test
    func matchesGoogleChromeUserAndSystemLookupOrder() {
        let folders = CEFNativeMessaging().googleChromeFolders(
            home: URL(fileURLWithPath: "/Users/example")
        )

        #expect(folders == [
            CEFNativeMessagingFolder(
                path: "/Users/example/Library/Application Support/Google/Chrome/NativeMessagingHosts",
                isUserLevel: true
            ),
            CEFNativeMessagingFolder(
                path: "/Library/Google/Chrome/NativeMessagingHosts",
                isUserLevel: false
            ),
        ])
    }
}
