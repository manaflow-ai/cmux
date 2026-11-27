import Foundation
import Testing
@testable import CmuxNextBrowser

/// Save Page As, Cast, QR code and Translate run through `cmux_shim_page_command`:
/// the Swift numbers are the header's, and each command has its catalog action.
@Suite struct BrowserPageCommandTests {
    @Test func numbersAreTheHeaderEnum() throws {
        let header = try String(contentsOf: CEFShimABITests.header, encoding: .utf8)
        let names: [BrowserPageCommand.Command: String] = [
            .saveAs: "CMUX_SHIM_PAGE_SAVE_AS", .cast: "CMUX_SHIM_PAGE_CAST",
            .qrCode: "CMUX_SHIM_PAGE_QR_CODE", .translate: "CMUX_SHIM_PAGE_TRANSLATE",
        ]
        for command in BrowserPageCommand.Command.allCases {
            let name = try #require(names[command])
            #expect(header.contains("\(name) = \(command.rawValue),"), "\(name)")
        }
        #expect(header.contains("CMUX_SHIM_EXPORT int cmux_shim_page_command(int browser_id, int command);"))
    }

    @Test func eachCommandHasItsAction() {
        #expect(BrowserPageCommand.Command.actions.map(\.0) == [
            "browser.savePageAs", "browser.cast", "browser.createQRCode", "browser.translate",
        ])
    }
}
