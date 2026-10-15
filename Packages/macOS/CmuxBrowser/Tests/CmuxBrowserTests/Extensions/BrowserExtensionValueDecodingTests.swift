import AppKit
import Foundation
import Testing
@testable import CmuxBrowser

@Suite("Browser extension fork JSON decoding")
struct BrowserExtensionValueDecodingTests {
    @Test
    func listDecodesAllFieldsAndSortsByName() throws {
        let json = """
        [{"id":"b","name":"zeta","version":"1.2","description":"Z","manifest_version":2,"location":"webstore",
          "enabled":true,"terminated":false,"blocklisted":false,"disable_reasons":[1],"has_action":true,
          "pinned":true,"may_modify":true,"must_remain_enabled":false,"options_url":"chrome-extension://b/o.html",
          "icon_path":"/i.png","path":"/ext/b"},
         {"id":"a","name":"Alpha","location":"command_line","enabled":false,"terminated":true}]
        """
        let list = BrowserExtensionInfo.decodeList(json)
        #expect(list.map(\.id) == ["a", "b"])
        let zeta = try #require(list.last)
        #expect(zeta.version == "1.2")
        #expect(zeta.manifestVersion == 2)
        #expect(zeta.location == .webstore)
        #expect(zeta.disableReasons == [1])
        #expect(zeta.hasAction && zeta.isPinned)
        #expect(zeta.optionsURL?.absoluteString == "chrome-extension://b/o.html")
        #expect(zeta.iconPath == "/i.png")
        #expect(zeta.path == "/ext/b")
        let alpha = try #require(list.first)
        #expect(alpha.location == .commandLine)
        #expect(alpha.isTerminated)
        #expect(!alpha.canRemove)
    }

    @Test(arguments: ["", "not json", "{}", "[{\"name\":\"no id\"}]"])
    func invalidListYieldsEmpty(_ json: String) {
        #expect(BrowserExtensionInfo.decodeList(json).isEmpty)
    }

    @Test
    func canToggleRespectsPolicyAndBlocklist() {
        #expect(BrowserExtensionInfo(id: "x", name: "x").canToggle)
        #expect(!BrowserExtensionInfo(id: "x", name: "x", mayModify: false).canToggle)
        #expect(!BrowserExtensionInfo(id: "x", name: "x", mustRemainEnabled: true).canToggle)
        #expect(BrowserExtensionInfo(id: "x", name: "x", isEnabled: false, mustRemainEnabled: true).canToggle)
        #expect(!BrowserExtensionInfo(id: "x", name: "x", isBlocklisted: true).canToggle)
    }

    @Test
    func actionsDecodeAndFallBackForOlderForks() throws {
        let png = Data([0x89, 0x50]).base64EncodedString()
        let json = """
        [{"id":"e","name":"Ext","title":"Do it","badge":"3","badge_color":"#FF000080","pinned":true,
          "has_popup":true,"enabled":false,"icon_png":"\(png)"}]
        """
        let actions = BrowserExtensionAction.decodeList(json)
        let action = try #require(actions.first)
        #expect(action.title == "Do it")
        #expect(action.badge == "3")
        #expect(action.isPinned && action.hasPopup && !action.isEnabled)
        #expect(action.iconPNG == Data([0x89, 0x50]))
        let fallback = BrowserExtensionInfo.fromActions(actions)
        #expect(fallback.first?.mayModify == false)
        #expect(fallback.first?.isPinned == true)
    }

    @Test
    func badgeColorParsing() throws {
        let rgba = try #require(BrowserExtensionAction.rgba("#FF000080"))
        #expect(rgba.red == 1 && rgba.green == 0 && rgba.blue == 0)
        #expect(abs(rgba.alpha - 128.0 / 255) < 0.0001)
        #expect(BrowserExtensionAction.rgba("00FF00")?.alpha == 1)
        #expect(BrowserExtensionAction.rgba("#12345") == nil)
        #expect(BrowserExtensionAction.rgba("#GGGGGG") == nil)
    }

    @Test
    func commandsDecodeAndMatchKeys() throws {
        let json = """
        [{"extension_id":"e","name":"_execute_action","key_code":89,"modifiers":18,"shortcut":"⌘⇧Y"},
         {"extension_id":"e","name":"toggle","key_code":113,"modifiers":4,"global":true}]
        """
        let commands = BrowserExtensionCommand.decodeList(json)
        #expect(commands.count == 2)
        let execute = try #require(commands.first)
        #expect(execute.isExecuteAction)
        #expect(execute.modifierFlags == [.command, .shift])
        #expect(execute.matches(macKeyCode: 16, characters: "Y", modifierFlags: [.command, .shift]))
        #expect(!execute.matches(macKeyCode: 16, characters: "y", modifierFlags: [.command]))
        let toggle = try #require(commands.last)
        #expect(toggle.isGlobal && !toggle.isExecuteAction)
        #expect(toggle.key == "f2")
        #expect(toggle.matches(macKeyCode: 120, characters: "\u{F705}", modifierFlags: [.control]))
        let digit = BrowserExtensionCommand(extensionID: "e", name: "one", keyCode: 0x31, modifiers: 4 | 2)
        #expect(digit.matches(macKeyCode: 18, characters: "!", modifierFlags: [.control, .shift]), "Shift does not change the key")
    }

    @Test
    func installPromptDecodes() throws {
        let icon = Data([1, 2, 3]).base64EncodedString()
        let json = """
        {"type":"permissions","extension_id":"e","name":"Ext","icon_png":"\(icon)",
         "permissions":[{"message":"Read your history"},{"message":""},{"message":"Sites","details":"a.com"}],
         "withhold_on_accept":true}
        """
        let prompt = try #require(BrowserExtensionInstallPrompt(id: 4, browser: 7, json: json))
        #expect(prompt.kind == .permissions)
        #expect(prompt.icon == Data([1, 2, 3]))
        #expect(prompt.permissions == [.init(message: "Read your history"), .init(message: "Sites", details: "a.com")])
        #expect(prompt.withholdsOnAccept)
        #expect(prompt.browser == 7)
        #expect(BrowserExtensionInstallPrompt(id: 1, browser: 0, json: "{\"type\":\"mystery\"}")?.kind == .other)
        #expect(BrowserExtensionInstallPrompt(id: 1, browser: 0, json: "{\"type\":\"installed\"}") == nil)
        #expect(BrowserExtensionInstallPrompt(id: 1, browser: 0, json: "nope") == nil)
    }

    @Test
    func installedNoticeDecodes() {
        let notice = BrowserExtensionInstalledNotice(json: "{\"type\":\"installed\",\"extension_id\":\"e\",\"name\":\"N\"}")
        #expect(notice?.extensionID == "e")
        #expect(notice?.name == "N")
        #expect(BrowserExtensionInstalledNotice(json: "{\"type\":\"installed\"}") == nil)
        #expect(BrowserExtensionInstalledNotice(json: "{\"type\":\"install\",\"extension_id\":\"e\"}") == nil)
    }

    @Test
    func pagesHaveExpectedURLs() {
        #expect(BrowserExtensionPage.webStore.url.host == "chromewebstore.google.com")
        #expect(BrowserExtensionPage.management.url.absoluteString == "chrome://extensions/")
    }
}
