import Foundation
import Testing
@testable import CmuxNextBrowser

@Suite struct CEFExtensionActionTests {
    @Test func decodesForkJSON() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString()
        let json = """
        [{"id":"abc","name":"uBlock Origin","title":"uBlock Origin (on)","badge":"12",
          "badge_color":"#FF0000FF","badge_text_color":"#FFFFFFFF","enabled":true,
          "pinned":false,"has_popup":true,"icon_png":"\(png)"},
         {"id":"def"}]
        """
        let actions = CEFExtensionAction.decodeList(json)
        #expect(actions.count == 2)
        #expect(actions[0].name == "uBlock Origin")
        #expect(actions[0].badge == "12")
        #expect(actions[0].hasPopup)
        #expect(actions[0].iconPNG == Data([0x89, 0x50, 0x4E, 0x47]))
        #expect(actions[1].name == "def")
        #expect(actions[1].isEnabled)
    }

    @Test func invalidJSONIsEmpty() {
        #expect(CEFExtensionAction.decodeList("nope").isEmpty)
        #expect(CEFExtensionAction.decodeList("{}").isEmpty)
    }

    @Test func parsesColors() throws {
        let red = try #require(CEFExtensionAction.rgba("#FF000080"))
        #expect(red.red == 1 && red.green == 0 && abs(red.alpha - 128.0 / 255) < 1e-9)
        let opaque = try #require(CEFExtensionAction.rgba("00FF00"))
        #expect(opaque.green == 1 && opaque.alpha == 1)
        #expect(CEFExtensionAction.rgba("#12") == nil)
    }
}

@Suite struct CEFDevToolsResultTests {
    @Test func evaluationReturnsValue() throws {
        let value = try CEFDevToolsResult.evaluation(#"{"result":{"type":"number","value":42}}"#)
        #expect(value == .number(42))
        let object = try CEFDevToolsResult.evaluation(#"{"result":{"type":"object","value":{"a":[true,"x"]}}}"#)
        #expect(object == .object(["a": .array([.bool(true), .string("x")])]))
        #expect(try CEFDevToolsResult.evaluation(#"{"result":{"type":"undefined"}}"#) == .null)
    }

    @Test func evaluationThrowsPageExceptions() {
        let json = #"{"result":{"type":"object"},"exceptionDetails":{"text":"Uncaught","exception":{"description":"ReferenceError: x is not defined"}}}"#
        #expect(throws: BrowserTabError.javaScript("ReferenceError: x is not defined")) {
            try CEFDevToolsResult.evaluation(json)
        }
    }

    @Test func frameAndContextIDs() {
        #expect(CEFDevToolsResult.mainFrameID(#"{"frameTree":{"frame":{"id":"F1"}}}"#) == "F1")
        #expect(CEFDevToolsResult.executionContextID(#"{"executionContextId":5}"#) == 5)
        #expect(CEFDevToolsResult.mainFrameID("{}") == nil)
    }

    @Test func screenshotRejectsGarbage() {
        #expect(throws: BrowserTabError.snapshotUnavailable) {
            try CEFDevToolsResult.screenshot(#"{"data":"AAAA"}"#)
        }
    }
}

@Suite struct CEFStorageAndLayoutTests {
    @Test func profilesAreDirectChildrenOfTheRoot() {
        let storage = CEFProfileStorage.forApplication(
            bundleIdentifier: "com.cmuxterm.app.debug.x", applicationSupport: URL(filePath: "/AS")
        )
        #expect(storage.root.path == "/AS/com.cmuxterm.app.debug.x/Chromium")
        let profile = storage.cachePath(for: .default)
        // Chrome style: any deeper path becomes an off-the-record profile.
        #expect(profile.deletingLastPathComponent().standardizedFileURL.path == storage.root.standardizedFileURL.path)
        #expect(profile.lastPathComponent == "Profile-" + BrowserProfileID.default.rawValue.uuidString)
    }

    @Test func picksTheBaseHelper() {
        let entries = ["cmux DEV x Helper (GPU).app", "cmux DEV x Helper.app", "Chromium Embedded Framework.framework",
                       "cmux DEV x Helper (Renderer).app", "libcmux_cef_shim.dylib"]
        #expect(CEFRuntimeLayout.baseHelperName(in: entries) == "cmux DEV x Helper.app")
        #expect(CEFRuntimeLayout.baseHelperName(in: ["x.framework"]) == nil)
    }

    @Test func locatesAnOverrideDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-layout-\(UUID().uuidString)")
        let frameworks = root.appending(path: "Demo.app/Contents/Frameworks")
        for name in [CEFRuntimeLayout.frameworkName, "Demo Helper.app"] {
            try FileManager.default.createDirectory(at: frameworks.appending(path: name), withIntermediateDirectories: true)
        }
        FileManager.default.createFile(atPath: frameworks.appending(path: CEFRuntimeLayout.shimName).path, contents: Data())
        defer { try? FileManager.default.removeItem(at: root) }

        let layout = try #require(CEFRuntimeLayout.locate(environment: ["CMUX_NEXT_CEF_RUNTIME": frameworks.path]))
        #expect(layout.mainBundle.lastPathComponent == "Demo.app")
        #expect(layout.helperExecutable.path.hasSuffix("Demo Helper.app/Contents/MacOS/Demo Helper"))
        #expect(layout.frameworkBinary.lastPathComponent == "Chromium Embedded Framework")
    }

    @Test func missingRuntimeMeansUnavailable() {
        let engine = CEFEngine(layout: nil)
        #expect(!engine.availability.isAvailable)
    }
}
