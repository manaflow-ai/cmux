import AppKit
import Testing

@testable import CmuxBrowser

/// The tab pasteboard a REPL Copy, Cut or Paste runs against must reach
/// WebKit's command and nothing else, and WebKit's command must never reach
/// the system pasteboard. These tests compare pasteboard identities only;
/// they never read or write the system pasteboard's contents.
@MainActor
@Suite("Browser REPL pasteboard redirect", .serialized)
struct BrowserReplPasteboardRedirectTests {
    private let general = NSPasteboard.Name.general.rawValue

    @Test func otherCodeGetsTheSystemPasteboardDuringAndAfterACommand() async throws {
        let system = NSPasteboard(name: .general)
        #expect(BrowserReplPasteboardRedirect.install())
        let tab = NSPasteboard.withUniqueName()
        defer { tab.releaseGlobally() }

        var during: [NSPasteboard] = []
        let outcome = await BrowserReplPasteboardRedirect.run(on: tab, timeout: .seconds(5)) { done in
            // The terminal or any other cmux code looking up the general
            // pasteboard while WebKit's command is in flight.
            during.append(NSPasteboard(name: .general))
            during.append(NSPasteboard.general)
            done()
        }
        #expect(outcome == .completed)
        #expect(during.count == 2)
        #expect(during.allSatisfy { $0 === system }, "a lookup by other code during a REPL command got the tab's pasteboard")
        #expect(NSPasteboard(name: .general) === system)
        #expect(BrowserReplPasteboardRedirect.redirectTarget(forLookupOf: general, fromWebKit: false) == nil)
    }

    @Test func webKitKeepsTheTabPasteboardUntilItFinishesEvenAfterATimeout() async throws {
        #expect(BrowserReplPasteboardRedirect.install())
        let tab = NSPasteboard.withUniqueName()
        var finish: (@MainActor () -> Void)?
        let outcome = await BrowserReplPasteboardRedirect.run(on: tab, timeout: .milliseconds(50)) { done in
            finish = done
        }
        #expect(outcome == .timedOut)
        // A paste WebKit performs late must still read the tab's pasteboard,
        // never the user's clipboard.
        #expect(BrowserReplPasteboardRedirect.redirectTarget(forLookupOf: general, fromWebKit: true) === tab)
        #expect(BrowserReplPasteboardRedirect.redirectTarget(forLookupOf: "Apple CFPasteboard find", fromWebKit: true) == nil)
        try #require(finish != nil)
        finish?()
        #expect(BrowserReplPasteboardRedirect.redirectTarget(forLookupOf: general, fromWebKit: true) == nil)
    }

    @Test func aCommandDoesNotStartWhileAnEarlierOneIsUnfinished() async throws {
        #expect(BrowserReplPasteboardRedirect.install())
        let first = NSPasteboard.withUniqueName()
        let second = NSPasteboard.withUniqueName()
        defer { second.releaseGlobally() }
        var finishFirst: (@MainActor () -> Void)?
        let firstOutcome = await BrowserReplPasteboardRedirect.run(on: first, timeout: .milliseconds(50)) { done in
            finishFirst = done
        }
        #expect(firstOutcome == .timedOut)

        var secondStarted = false
        let secondOutcome = await BrowserReplPasteboardRedirect.run(on: second, timeout: .milliseconds(50)) { done in
            secondStarted = true
            done()
        }
        #expect(secondOutcome == .busy)
        #expect(!secondStarted, "a second command ran while WebKit could still be using the first one's pasteboard")

        finishFirst?()
        let thirdOutcome = await BrowserReplPasteboardRedirect.run(on: second, timeout: .seconds(5)) { done in
            secondStarted = true
            done()
        }
        #expect(thirdOutcome == .completed)
        #expect(secondStarted)
    }
}
