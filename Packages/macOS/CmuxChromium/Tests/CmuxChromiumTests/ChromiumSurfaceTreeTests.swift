import Foundation
import Testing
@testable import CmuxChromium

struct ChromiumSurfaceTreeTests {
    @Test func decodesNativeMenuSurface() throws {
        let json = """
        {"generation": 7, "surfaces": [{
          "surfaceId": 3, "parentSurfaceId": 1, "kind": 2, "contextId": 0,
          "x": 10, "y": 20, "width": 200, "height": 150, "scale": 2.0,
          "zIndex": 1, "visible": true,
          "menuItems": ["One", "Two"],
          "nativeMenuItems": [
            {"label": "One", "toolTip": "", "enabled": true, "separator": false, "group": false, "textDirection": 0, "hasTextDirectionOverride": false},
            {"label": "Two", "toolTip": "", "enabled": false, "separator": false, "group": false, "textDirection": 0, "hasTextDirectionOverride": false}
          ],
          "selectedIndex": 1, "itemFontSize": 13.0, "rightAligned": false,
          "filePickerMode": "", "filePickerAcceptTypes": [], "filePickerAllowsMultiple": false,
          "filePickerUploadFolder": false, "label": ""
        }]}
        """
        let tree = try ChromiumSurfaceTree(json: json)
        #expect(tree.generation == 7)
        let surface = try #require(tree.surfaces.first)
        #expect(surface.kind == .nativeMenu)
        #expect(surface.nativeMenuItems.count == 2)
        #expect(surface.nativeMenuItems[1].enabled == false)
        #expect(surface.selectedIndex == 1)
    }

    @Test func unknownKindDecodesAsUnknown() throws {
        let json = """
        {"generation": 1, "surfaces": [{"surfaceId": 1, "parentSurfaceId": 0, "kind": 99,
          "contextId": 0, "x": 0, "y": 0, "width": 1, "height": 1, "scale": 1, "zIndex": 0,
          "visible": true, "menuItems": [], "nativeMenuItems": [], "selectedIndex": -1,
          "itemFontSize": 0, "rightAligned": false, "filePickerMode": "",
          "filePickerAcceptTypes": [], "filePickerAllowsMultiple": false,
          "filePickerUploadFolder": false, "label": ""}]}
        """
        let tree = try ChromiumSurfaceTree(json: json)
        #expect(tree.surfaces.first?.kind == .unknown)
    }
}

struct ChromiumSurfaceCaptureTests {
    @Test func decodesCapturePNG() throws {
        // 1x1 transparent PNG.
        let pngBase64 =
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        let json = """
        {"pngBase64": "\(pngBase64)", "width": 1, "height": 1, "captureMode": "software", "error": ""}
        """
        let capture = try ChromiumSurfaceCapture(json: json)
        #expect(capture.width == 1)
        #expect(capture.height == 1)
        #expect(capture.pngData == Data(base64Encoded: pngBase64))
    }

    @Test func throwsOnNonEmptyError() {
        let json = """
        {"pngBase64": "", "width": 0, "height": 0, "captureMode": "", "error": "capture failed"}
        """
        #expect(throws: ChromiumRuntimeError.self) {
            try ChromiumSurfaceCapture(json: json)
        }
    }
}
