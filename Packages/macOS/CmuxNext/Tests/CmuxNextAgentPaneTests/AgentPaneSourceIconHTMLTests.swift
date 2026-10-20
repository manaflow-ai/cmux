import Foundation
import Testing
@testable import CmuxNextAgentPane

struct AgentPaneSourceIconHTMLTests {
    private func urls(_ html: String, page: String = "https://leafdraft.com/") throws -> [String] {
        let url = try #require(URL(string: page))
        return AgentPaneSourceIconHTML().candidates(in: Data(html.utf8), pageURL: url).map(\.absoluteString)
    }

    @Test func absoluteCDNAndRelativeIcons() throws {
        #expect(try urls("""
            <head><link rel="shortcut icon" href="https://nodeassets.nbcnews.com/favicon.ico">
            <link rel="icon" type="image/png" sizes="32x32" href="https://nodeassets.nbcnews.com/favicon-32x32.png">
            """) == ["https://nodeassets.nbcnews.com/favicon-32x32.png", "https://nodeassets.nbcnews.com/favicon.ico"])
        #expect(try urls("""
            <link rel="icon" href="/favicon.svg"><link rel="icon" href="/favicon.svg">
            <link rel="icon" href="/favicon.png">
            """) == ["https://leafdraft.com/favicon.png"])
    }

    @Test func svgCandidatesAreExcludedByTypeAndSuffixBeforeRanking() throws {
        #expect(try urls("""
            <link rel=icon type="image/svg+xml; charset=utf-8" href=/typed sizes=32x32>
            <link rel=icon type="IMAGE/SVG+XML" href=/typed-case sizes=32x32>
            <link rel=icon href=/mark.SVG?version=2 sizes=32x32>
            <link rel=icon href=/mark.svgz sizes=32x32>
            <link rel=icon href=/raster.png sizes=64x64>
            """) == ["https://leafdraft.com/raster.png"])
    }

    @Test func fragmentsDoNotCreateDistinctIconRequests() throws {
        #expect(try urls("<link rel=icon href=/favicon.ico#one><link rel=icon href=/favicon.ico#two>")
                == ["https://leafdraft.com/favicon.ico"])
    }

    @Test func baseAndRelTokensAndEntityDecoding() throws {
        #expect(try urls("""
            <head><BASE HREF="https://cdn.example/assets/">
            <LINK REL="alternate\tICON shortcut" HREF="mark.png?a=1&amp;b=2" sizes="64x64">
            <link rel="apple-touch-icon" href="touch.png" sizes="32x32">
            <link rel="icon mask-icon" href="mask.svg">
            <link rel="not-an-icon" href="no.png">
            """) == ["https://cdn.example/assets/mark.png?a=1&b=2", "https://cdn.example/assets/touch.png"])
    }

    @Test func unsafeURLsAndInertMarkupAreSkipped() throws {
        #expect(try urls("""
            <!-- <link rel=icon href=/comment.png> -->
            <script>const s = '<link rel=icon href=/script.png>';</script>
            <link rel=icon href=http://public.example/a.png>
            <link rel=icon href=https://127.0.0.1/a.png>
            <link rel=icon href=https://169.254.169.254/a.png>
            <link rel=icon href=https://[::1]/a.png>
            <link rel=icon href=https://localhost/a.png>
            <link rel=icon href=https://private.internal/a.png>
            <link rel=icon href=https://user:pass@public.example/a.png>
            <link rel=icon href=data:image/svg+xml,anything>
            """).isEmpty)
    }

    @Test func sizesRankBeforeUnsizedAndTouchIcons() throws {
        #expect(try urls("""
            <link rel=apple-touch-icon href=/touch.png sizes=32x32>
            <link rel=icon href=/any.svg sizes=any>
            <link rel=icon href=/large.png sizes=256x256>
            <link rel=icon href=/small.ico sizes=16x16>
            <link rel=icon href=/best.png sizes="16x16 48x48">
            <link rel=icon href=/plain.png>
            """) == ["https://leafdraft.com/best.png", "https://leafdraft.com/small.ico",
                       "https://leafdraft.com/large.png", "https://leafdraft.com/plain.png",
                       "https://leafdraft.com/touch.png"])
    }

    @Test func truncatedBodyStillYieldsCompletedHeadLinks() throws {
        let html = "<html><head><link rel=icon href=/favicon.png></head><body>" + String(repeating: "x", count: 300_000)
        let prefix = String(decoding: Data(html.utf8).prefix(256 * 1024), as: UTF8.self)
        #expect(try urls(prefix) == ["https://leafdraft.com/favicon.png"])
    }

    @Test func commentAndScriptLinksAreIgnored() throws {
        #expect(try urls("""
            <!-- <base href=https://wrong.example/><link rel=icon href=/comment.png> -->
            <script>const s = '<link rel="icon" href="/script.png">'; if (a<b) {} </script>
            <link rel=icon href=/real.png>
            """) == ["https://leafdraft.com/real.png"])
    }

    @Test func singleQuotedUnquotedAndValuelessAttributes() throws {
        #expect(try urls("""
            <link disabled rel='shortcut icon' href='/single.png' sizes='32x32'>
            <link rel=icon href=/unquoted.png sizes=32x32>
            <link rel href=/valueless.png>
            """) == ["https://leafdraft.com/single.png", "https://leafdraft.com/unquoted.png"])
    }

    @Test func attributeEntitiesAreDecodedOnce() throws {
        #expect(try urls("""
            <link rel='&#105;co&#x6e;' href='/icon.png?a=1&amp;b=&#50;&#x33;&amp;c=&amp;quot;'>
            """) == ["https://leafdraft.com/icon.png?a=1&b=23&c=&quot;"])
    }

    @Test(arguments: ["<body>", "<BoDy class='main'>", "</head>", "</HeAd>"])
    func linksAfterHeadAreIgnored(boundary: String) throws {
        #expect(try urls("<link rel=icon href=/head.png>" + boundary + "<link rel=icon href=/body.png>")
                == ["https://leafdraft.com/head.png"])
    }

    @Test func mixedCaseTagAndAttributeNames() throws {
        #expect(try urls("<HeAd><LiNk ReL='IcOn' HrEf=/mixed.png SiZeS=32x32></hEaD>")
                == ["https://leafdraft.com/mixed.png"])
    }

    @Test(arguments: ["script", "style", "template", "noscript", "textarea", "title"])
    func inertElementContentsAreIgnored(tag: String) throws {
        #expect(try urls("""
            <\(tag)><body><base href=https://wrong.example/><link rel=icon href=/inert.png></\(tag)>
            <link rel=icon href=/real.png>
            """) == ["https://leafdraft.com/real.png"])
    }

    @Test func nestedTemplatesAreIgnored() throws {
        #expect(try urls("""
            <template><template><link rel=icon href=/nested.png></template>
            <script>const s = '</template>';</script><link rel=icon href=/outer.png></template>
            <link rel=icon href=/real.png>
            """) == ["https://leafdraft.com/real.png"])
    }

    @Test func firstBaseHrefWinsEvenWhenAfterLinks() throws {
        #expect(try urls("""
            <base target=_blank><link rel=icon href=icon.png>
            <base href=https://first.example/assets/><base href=https://second.example/>
            """) == ["https://first.example/assets/icon.png"])
    }

    @Test func linkCountAndAttributeLengthAreBounded() throws {
        let ignoredLinks = String(repeating: "<link rel=alternate href=/unused.png>", count: 64)
        #expect(try urls(ignoredLinks + "<link rel=icon href=/late.png>").isEmpty)
        let oversized = String(repeating: "x", count: 2049)
        #expect(try urls("""
            <link rel=icon href='\(oversized)' href=/duplicate.png>
            <link rel=icon href=/real.png sizes='\(oversized)'>
            """) == ["https://leafdraft.com/real.png"])
    }

    @Test func lossyUTF8AndTruncatedTags() throws {
        let page = try #require(URL(string: "https://leafdraft.com/"))
        var bytes = Data([0xff])
        bytes.append(contentsOf: "<link rel=icon href=/real.png><link rel=icon href='/unfinished.png".utf8)
        #expect(AgentPaneSourceIconHTML().candidates(in: bytes, pageURL: page).map(\.absoluteString)
                == ["https://leafdraft.com/real.png"])
    }
}
