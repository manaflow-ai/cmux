import Foundation
import Testing
@testable import CmuxControlSocket

@Suite("Browser extension control requests")
struct BrowserExtensionControlRequestTests {
    private func parse(_ verb: String, _ arguments: String...) throws -> BrowserExtensionControlRequest {
        try BrowserExtensionControlRequest(verb: verb, arguments: arguments, currentDirectory: "/work")
    }

    @Test
    func listIsTheDefaultAndQuick() throws {
        let empty = try parse("")
        #expect(empty.method == "browser.extension.list")
        #expect(empty.responseTimeout == BrowserExtensionControlRequest.quickSeconds)
        #expect(try parse("LS").method == "browser.extension.list")
    }

    @Test
    func consentVerbsOutwaitTheAppsSheet() throws {
        for request in [try parse("load", "ext"), try parse("enable", "x"), try parse("run", "x"),
                        try parse("reload", "x"), try parse("command", "x", "go")] {
            #expect(request.responseTimeout > BrowserExtensionControlRequest.consentSeconds, "\(request.method)")
        }
        for request in [try parse("disable", "x"), try parse("remove", "x"), try parse("pin", "x"),
                        try parse("unpin", "x"), try parse("options", "x"), try parse("webstore")] {
            #expect(request.responseTimeout == BrowserExtensionControlRequest.quickSeconds, "\(request.method)")
        }
    }

    @Test
    func loadResolvesRelativePathsAndRoutesCrxToTheRefusal() throws {
        #expect(try parse("load", "ext/../my-ext").params["path"] == "/work/my-ext")
        #expect(try parse("load-unpacked", "/abs/dir").params["path"] == "/abs/dir")
        let crx = try parse("load", "thing.CRX")
        #expect(crx.method == "browser.extension.install_crx")
    }

    @Test
    func argumentsMapToParams() throws {
        #expect(try parse("move", "abc", "2").params == ["extension": "abc", "index": "2"])
        #expect(try parse("command", "abc", "toggle").params == ["extension": "abc", "command": "toggle"])
        #expect(try parse("manage").params == ["page": "manage"])
    }

    @Test
    func badInputThrowsTypedErrors() {
        #expect(throws: BrowserExtensionControlRequest.ParseError.wrongArgumentCount) { try parse("enable") }
        #expect(throws: BrowserExtensionControlRequest.ParseError.wrongArgumentCount) { try parse("list", "extra") }
        #expect(throws: BrowserExtensionControlRequest.ParseError.invalidIndex) { try parse("move", "x", "-1") }
        #expect(throws: BrowserExtensionControlRequest.ParseError.invalidIndex) { try parse("move", "x", "two") }
        #expect(throws: BrowserExtensionControlRequest.ParseError.unknownVerb("install")) { try parse("install", "x") }
    }
}
