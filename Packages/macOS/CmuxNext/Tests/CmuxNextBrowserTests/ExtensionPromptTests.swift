import Foundation
import Testing
@testable import CmuxNextBrowser

/// Extension install and permission prompts (fork API 12), the new-tab page
/// and native messaging folders.
@Suite struct ExtensionPromptTests {
    @Test func installPromptDecodes() throws {
        let icon = Data([0x89, 0x50]).base64EncodedString()
        let json = """
        {"type":"install","extension_id":"abc","name":"Dark Reader","icon_png":"\(icon)",
         "permissions":[{"message":"Read and change all your data on all websites","details":""},{"message":"","details":"x"}],
         "withhold_on_accept":true,"webstore":{"rating":4.7}}
        """
        let prompt = try #require(ExtensionInstallPrompt(id: 7, browser: 3, json: json))
        #expect(prompt.kind == .install)
        #expect(prompt.extensionID == "abc")
        #expect(prompt.name == "Dark Reader")
        #expect(prompt.icon == Data([0x89, 0x50]))
        #expect(prompt.permissions == [.init(message: "Read and change all your data on all websites", details: "")])
        #expect(prompt.withholdsOnAccept)
        #expect(prompt.browser == 3)
    }

    @Test func permissionPromptAndUnknownTypes() throws {
        #expect(ExtensionInstallPrompt(id: 1, browser: 0, json: #"{"type":"permissions","name":"X"}"#)?.kind == .permissions)
        #expect(ExtensionInstallPrompt(id: 1, browser: 0, json: #"{"type":"something_new","name":"X"}"#)?.kind == .other)
        #expect(ExtensionInstallPrompt(id: 1, browser: 0, json: "not json") == nil)
        #expect(ExtensionInstallPrompt(id: 0, browser: 0, json: #"{"type":"installed","extension_id":"a"}"#) == nil,
                "the installed notice is not a prompt")
    }

    @Test func installedNoticeDecodes() {
        #expect(ExtensionInstalledNotice(json: #"{"type":"installed","extension_id":"a","name":"A"}"#)?.name == "A")
        #expect(ExtensionInstalledNotice(json: #"{"type":"install","extension_id":"a"}"#) == nil)
    }

    @MainActor @Test func sheetTextNamesTheExtensionAndItsAccess() {
        let prompt = ExtensionInstallPrompt(id: 1, kind: .permissions, extensionID: "a", name: "Tool",
                                            permissions: [.init(message: "Read your history", details: "")])
        #expect(ExtensionPromptSheet.title(for: prompt).contains("Tool"))
        #expect(ExtensionPromptSheet.body(for: prompt).contains("Read your history"))
        #expect(ExtensionPromptSheet.acceptTitle(for: .permissions) != ExtensionPromptSheet.acceptTitle(for: .install))
        let bare = ExtensionInstallPrompt(id: 2, kind: .install, extensionID: "b", name: "B")
        #expect(!ExtensionPromptSheet.body(for: bare).isEmpty)
    }

    @Test func shimEventsDecode() {
        let prompt = CEFShimEvent(kind: 29, browser: 4, request: 9, a: 0, b: 0, s1: "{}", s2: "")
        #expect(prompt == .installPrompt(browser: 4, promptID: 9, json: "{}"))
        let rows = CEFShimEvent(kind: 30, browser: 0, request: 5, a: 0, b: 0, s1: "ext", s2: "[]")
        #expect(rows == .omniboxSuggestions(requestID: 5, extensionID: "ext", json: "[]"))
    }

    @Test func newTabPage() {
        #expect(BrowserNewTabPage.initialURL(for: .cef) == "chrome://newtab/")
        #expect(BrowserNewTabPage.initialURL(for: .webkit) == "about:blank")
        #expect(BrowserNewTabPage.isNewTabPage(URL(string: "chrome://newtab/")))
        #expect(BrowserNewTabPage.isNewTabPage(URL(string: "CHROME://NEWTAB")))
        #expect(!BrowserNewTabPage.isNewTabPage(URL(string: "chrome://extensions/")))
        #expect(BrowserURLDisplay.displayText(for: URL(string: "chrome://newtab/")) == "")
        #expect(BrowserURLDisplay.editingText(for: URL(string: "chrome://newtab/")) == "")
        #expect(BrowserURLDisplay.title(for: BrowserTabState(url: URL(string: "chrome://newtab/"))) == nil)
    }

    @Test func nativeMessagingFoldersFollowCmuxs() {
        let folders = CEFNativeMessaging.googleChromeFolders(home: URL(filePath: "/Users/me"))
        #expect(folders == [
            .init(path: "/Users/me/Library/Application Support/Google/Chrome/NativeMessagingHosts", isUserLevel: true),
            .init(path: "/Library/Google/Chrome/NativeMessagingHosts", isUserLevel: false),
        ])
    }
}

/// Extension popup windows (chrome.windows.create type popup) stay off on
/// forks whose popup-window hooks do not work yet (cmux.10, API 12).
@Suite struct PopupWindowGateTests {
    @Test func olderForksKeepTheOldBehavior() {
        #expect(!CEFPopupWindows.isEnabled(forkAPIVersion: 10))
        #expect(!CEFPopupWindows.isEnabled(forkAPIVersion: 12))
        #expect(CEFPopupWindows.isEnabled(forkAPIVersion: CEFPopupWindows.minimumForkAPI))
    }
}
