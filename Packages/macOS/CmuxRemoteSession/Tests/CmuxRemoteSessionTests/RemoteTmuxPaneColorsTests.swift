import Foundation
import Testing
@testable import CmuxRemoteSession

@Suite struct RemoteTmuxPaneColorsTests {
    @Test func reportsBothEndpointsWithoutChangingPaneStyleOrSendingInput() throws {
        let colors = try #require(RemoteTmuxPaneColors(
            foreground: "#F0F6FC", background: "#0D1117"
        ))
        #expect(colors.foreground == "#f0f6fc")
        #expect(colors.background == "#0d1117")
        #expect(colors.reportCommands(paneId: 36) == [
            "refresh-client -r \"%36:\\033]10;rgb:f0f0/f6f6/fcfc\\007\"",
            "refresh-client -r \"%36:\\033]11;rgb:0d0d/1111/1717\\007\"",
        ])
    }

    @Test func lightThemeAndCustomColorsAreNotReplacedWithDarkDefaults() throws {
        let colors = try #require(RemoteTmuxPaneColors(
            foreground: "#1f2328", background: "#ffffff"
        ))
        #expect(colors.reportCommands(paneId: 7)[0].contains("]10;rgb:1f1f/2323/2828"))
        #expect(colors.reportCommands(paneId: 7)[1].contains("]11;rgb:ffff/ffff/ffff"))
        let custom = try #require(RemoteTmuxPaneColors(
            foreground: "#123456", background: "#abcdef"
        ))
        #expect(custom.reportCommands(paneId: 8)[0].contains("]10;rgb:1212/3434/5656"))
        #expect(custom.reportCommands(paneId: 8)[1].contains("]11;rgb:abab/cdcd/efef"))
    }

    @Test(arguments: [
        "", "black", "#000", "#00000000", "#gggggg", "#+00000",
        "#123456\n", "#12345\"", "#1234;6", "#\u{ff11}\u{ff12}\u{ff13}"
    ])
    func rejectsNonHexEndpoints(_ value: String) {
        #expect(RemoteTmuxPaneColors(foreground: value, background: "#ffffff") == nil)
        #expect(RemoteTmuxPaneColors(foreground: "#000000", background: value) == nil)
    }

    @Test func controlCommandsRemainOneLineAndTargetTheRequestedPane() throws {
        let colors = try #require(RemoteTmuxPaneColors(
            foreground: "#000000", background: "#ffffff"
        ))
        for command in colors.reportCommands(paneId: 1234) {
            #expect(command.components(separatedBy: "\n").count == 1)
            #expect(!command.contains("\r"))
            #expect(!command.contains("\u{1b}"))
            #expect(command.components(separatedBy: "%1234:").count == 2)
            #expect(command.components(separatedBy: " -r ").count == 2)
            #expect(!command.contains("send-keys"))
            #expect(!command.contains("set-option"))
        }
    }
}
