import Foundation
import Testing
@testable import CmuxBrowser

@Suite("Browser extension prompt content")
struct BrowserExtensionPromptContentTests {
    @Test
    func chromiumPromptCarriesNameAndPermissions() {
        let permissions: [BrowserExtensionInstallPrompt.Permission] = [
            .init(message: "Read your history"), .init(message: "Sites", details: "a.com"),
        ]
        let prompt = BrowserExtensionInstallPrompt(id: 1, kind: .install, extensionID: "e", name: "Ext",
                                                   permissions: permissions)
        let content = BrowserExtensionPromptContent(prompt: prompt)
        #expect(content.title.contains("Ext"))
        #expect(content.target == "Ext")
        #expect(content.requester == nil)
        #expect(content.permissions == permissions)
        #expect(content.acceptTitle != content.cancelTitle)
    }

    @Test
    func noPermissionsChangesTheHeading() {
        let none = BrowserExtensionPromptContent(prompt: .init(id: 1, kind: .install, extensionID: "e", name: "E"))
        let some = BrowserExtensionPromptContent(prompt: .init(id: 1, kind: .install, extensionID: "e", name: "E",
                                                               permissions: [.init(message: "x")]))
        #expect(none.permissionsHeading != some.permissionsHeading)
    }

    @Test(arguments: [BrowserExtensionOperation.loadUnpacked, .enable, .run, .command])
    func automationConsentNamesRequesterAndTarget(_ operation: BrowserExtensionOperation) {
        let content = BrowserExtensionPromptContent(automation: operation, name: "/Users/me/my-ext")
        #expect(content.target == "/Users/me/my-ext")
        #expect(content.requester?.isEmpty == false)
        #expect(content.note?.isEmpty == false)
        #expect(!content.acceptTitle.isEmpty)
    }

    @Test
    func manifestSummaryListsSitesAndFeatures() {
        let narrow = BrowserExtensionManifestSummary(manifest: [
            "name": "N",
            "host_permissions": ["https://a.test/*"],
            "content_scripts": [["matches": ["https://b.test/*", "https://a.test/*"]]],
            "permissions": ["storage", "tabs", "storage"],
        ])
        #expect(narrow.name == "N")
        #expect(narrow.permissions.count == 2)
        #expect(narrow.permissions[0].details == "https://a.test/*\nhttps://b.test/*")
        #expect(narrow.permissions[1].details == "storage, tabs")
        let broad = BrowserExtensionManifestSummary(manifest: ["permissions": ["<all_urls>"]])
        #expect(broad.permissions.count == 1)
        #expect(broad.permissions[0].details.isEmpty)
        #expect(BrowserExtensionManifestSummary(manifest: [:]).permissions.isEmpty)
    }
}
