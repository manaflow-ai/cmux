import CmuxNextFocusUI
import Testing

/// The rules of the park for the text that a page waits for when its pane shows another page (New Tab key, a letter,
/// New Tab key). Each row has the park as a value, its own clock, and an object of the test for a page: no window,
/// no key router, no time that passes.
@MainActor
struct TypingParkTests {
    /// Stands for a page: the park knows a page by its object only.
    final class Page {}

    @Test func aParkedTextIsTakenOneTimeAndOnlyForItsPage() {
        var park = TypingPark<Page>()
        let page = Page(), other = Page()
        let start = ContinuousClock.now
        park.park("x", for: page, now: start)
        #expect(park.holds(page))
        #expect(!park.holds(other), "a text for one page waits for another page too")
        #expect(park.take(for: other, now: start + .milliseconds(10)) == nil, "another page got the text")

        #expect(park.take(for: page, now: start + .milliseconds(300)) == "x")
        #expect(park.isOnItsWay(to: page))
        #expect(park.take(for: page, now: start + .milliseconds(310)) == nil, "the text was taken 2 times")
        #expect(park.holds(page), "a text on its way no longer counts for its page: a key typed now would pass it")

        park.landed(in: page, typed: true)
        #expect(!park.holds(page))
        #expect(!park.isOnItsWay(to: page))
        var want = TypingPark<Page>.Counts()
        want.parked = 1
        want.typed = 1
        #expect(park.counts == want)
    }

    /// The limit is 2 s from the key that parked the text.
    @Test func aTextThatWaitedTheLimitIsDroppedAndCounted() {
        var park = TypingPark<Page>()
        #expect(park.limit == .seconds(2))
        let early = Page(), late = Page()
        let start = ContinuousClock.now
        park.park("a", for: early, now: start)
        park.park("b", for: late, now: start)
        #expect(park.take(for: early, now: start + .milliseconds(1999)) == "a", "a text below the limit was dropped")
        #expect(park.take(for: late, now: start + .seconds(2)) == nil, "a text at the limit was typed late")
        #expect(!park.holds(late))
        #expect(park.counts.droppedOld == 1)
        #expect(park.counts.typed == 0, "a text that only left the park counts as typed")

        // The text that was taken before the limit is on its way: the limit does not take it back.
        park.prune(now: start + .seconds(10))
        #expect(park.isOnItsWay(to: early))
        park.landed(in: early, typed: true)
        #expect(park.counts.typed == 1)
        #expect(park.counts.droppedOld == 1)
    }

    @Test func aTextWhosePageIsGoneIsDroppedAndCounted() {
        var park = TypingPark<Page>()
        let start = ContinuousClock.now
        var page: Page? = Page()
        if let page { park.park("x", for: page, now: start) }
        page = nil
        park.prune(now: start + .milliseconds(10))
        #expect(park.counts.droppedPageGone == 1)
        #expect(park.counts.droppedOld == 0)
        #expect(park.counts.parked == 1)
    }

    @Test func aTextThatTheFieldRefusedIsCountedAndNotTyped() {
        var park = TypingPark<Page>()
        let page = Page()
        let start = ContinuousClock.now
        park.park("x", for: page, now: start)
        #expect(park.take(for: page, now: start + .milliseconds(10)) == "x")
        park.landed(in: page, typed: false)
        #expect(park.counts.droppedRefused == 1)
        #expect(park.counts.typed == 0)
        #expect(!park.holds(page))
    }

    /// Two texts for one page: the second waits until the first landed, so the page gets them in the order of the keys.
    @Test func twoTextsForOnePageAreTakenInTheOrderOfTheirKeys() {
        var park = TypingPark<Page>()
        let page = Page()
        let start = ContinuousClock.now
        park.park("a", for: page, now: start)
        park.park("b", for: page, now: start + .milliseconds(100))
        #expect(park.take(for: page, now: start + .milliseconds(200)) == "a")
        #expect(park.take(for: page, now: start + .milliseconds(210)) == nil, "the second text passed the first")
        park.landed(in: page, typed: true)
        #expect(park.holds(page), "the second text went with the first")
        #expect(park.take(for: page, now: start + .milliseconds(220)) == "b")
        park.landed(in: page, typed: true)
        #expect(park.counts.parked == 2)
        #expect(park.counts.typed == 2)
        #expect(!park.holds(page))
    }

    /// The keys from a Return on that waited behind a text are not parked: the park counts them.
    @Test func theKeysFromAReturnOnAreCountedAtThePark() {
        var park = TypingPark<Page>()
        let page = Page()
        let start = ContinuousClock.now
        park.park("hello", for: page, droppingReturns: 2, now: start)
        #expect(park.take(for: page, now: start + .milliseconds(10)) == "hello", "the text of a dropped Return was dropped")
        park.landed(in: page, typed: true)
        #expect(park.counts.droppedReturns == 2)
        #expect(park.counts.named == ["parked": 1, "typed": 1, "dropped_old": 0, "dropped_page_gone": 0, "dropped_refused": 0,
                                      "dropped_returns": 2])
    }
}
