import AppKit
import Testing
@testable import MessagesLabHome

/// Crash program: the literals MessagesLab used to force-unwrap now go through non-trapping
/// constructors (CrashSafeGraphics). These pin that every literal still resolves, so the
/// fallbacks never run.
@Suite struct CrashSafeGraphicsTests {
    @Test func namedColorSpacesResolve() {
        #expect(CGColorSpace(name: CGColorSpace.sRGB) != nil)
        #expect(CGColorSpace(name: CGColorSpace.displayP3) != nil)
        #expect(LabColorSpace.displayP3.name == CGColorSpace.displayP3)
    }

    @Test func systemUIFontsResolve() {
        #expect(CTFontCreateUIFontForLanguage(.system, 13, nil) != nil)
        #expect(CTFontCreateUIFontForLanguage(.emphasizedSystem, 11, nil) != nil)
        #expect(CTFontGetSize(labUIFont(.system, 13)) == 13)
    }

    @Test func linkDetectorsAndMetaPatternsCompile() {
        #expect(TextParts.detector != nil)
        #expect(BlockLayout.detector != nil)
        #expect(TextParts.linkRuns("see https://cmux.com now").count == 1)
        let tags = LinkPreviews.metaTags(#"<meta property="og:title" content="cmux">"#)
        #expect(tags["og:title"] == "cmux")
    }
}
