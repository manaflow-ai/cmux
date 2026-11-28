import CmuxNextAgentPane
import CmuxNextControl
import CmuxNextSettings
import CoreGraphics
import Foundation
import Testing

/// `agent.chat.page.query` and `agent.chat.page.screenshot` (`cmux app chat page`): the checked
/// parameters, the mask's parse, and that the picture's words are greyed where the page measured them.
@Suite struct AgentChatPageControlTests {
    @Test func limitIsWholeAndInRange() throws {
        #expect(try AgentChatPageControl.limit([:]) == AgentChatPageControl.defaultLimit)
        #expect(try AgentChatPageControl.limit(["limit": 1]) == 1)
        #expect(try AgentChatPageControl.limit(["limit": .number(Double(AgentChatPageControl.maxLimit))]) == AgentChatPageControl.maxLimit)
        for bad: JSONValue in [0, .number(Double(AgentChatPageControl.maxLimit + 1)), .number(2.5), "5"] {
            #expect(throws: ControlError.self) { try AgentChatPageControl.limit(["limit": bad]) }
        }
    }

    @Test func stylesAreCSSPropertyNamesOnly() throws {
        #expect(try AgentChatPageControl.styles([:]).isEmpty)
        #expect(try AgentChatPageControl.styles(["styles": ["opacity", "--accent", "background-color"]]) == ["opacity", "--accent", "background-color"])
        for bad: JSONValue in ["opacity", [""], ["a;b"], ["x)"], .array(Array(repeating: "opacity", count: AgentChatPageControl.maxStyles + 1))] {
            #expect(throws: ControlError.self) { try AgentChatPageControl.styles(["styles": bad]) }
        }
    }

    @Test func maskParsesThePageAnswerAndRefusesAMalformedOne() {
        let mask = AgentChatPageControl.Mask(#"{"width":100,"height":50,"rects":[[1,2,3,4]]}"#)
        #expect(mask == AgentChatPageControl.Mask(width: 100, height: 50, rects: [CGRect(x: 1, y: 2, width: 3, height: 4)]))
        #expect(AgentChatPageControl.Mask(#"{"width":0,"height":50,"rects":[]}"#) == nil)
        #expect(AgentChatPageControl.Mask(#"{"width":100,"height":50,"rects":[[1,2,3]]}"#) == nil)
        #expect(AgentChatPageControl.Mask(nil) == nil)
    }

    /// A 2x picture of a 100x50 CSS page, black, with one text area at (10, 5) 20x10: that area
    /// (top-left origin, scaled) is grey, the rest still black.
    @Test func maskedGreysTheMeasuredAreasAtThePicturesScale() throws {
        let width = 200, height = 100
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let black = try #require(context.makeImage())
        let mask = AgentChatPageControl.Mask(width: 100, height: 50, rects: [CGRect(x: 10, y: 5, width: 20, height: 10)])
        let out = try #require(AgentChatPageControl.masked(black, by: mask))
        #expect(out.width == width && out.height == height)
        let pixels = try #require(out.dataProvider?.data as Data?)
        func red(_ x: Int, _ y: Int) -> UInt8 { pixels[y * out.bytesPerRow + x * 4] }  // row 0 is the top
        #expect(red(40, 20) > 100)  // inside the area: CSS (20, 10)
        #expect(red(5, 5) < 10)  // outside: still black
        #expect(red(40, 60) < 10)  // below the area
    }
}
