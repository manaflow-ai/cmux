import AppKit
import Dispatch
import Foundation
import os
import Testing
@testable import MessagesLabHome

/// The vendored catalyst A-L files' process-wide state, read and written from the row threads:
/// counters lose no concurrent bump, an off-main draw reads one palette and
/// its own elevated flag, and the guarded fetcher's per-task rules refuse what LinkGuard refuses.
@Suite struct CatalystSharedStateTests {
    static let threads = 8
    static let rounds = 5_000

    /// The counters were plain globals bumped by the measure threads: concurrent bumps were lost
    /// (or trapped in the exclusivity check). Other suites may add their own, never remove one.
    @Test func longTextCountersLoseNoConcurrentBump() {
        let before = LongTextStats.streamExtends
        DispatchQueue.concurrentPerform(iterations: Self.threads) { _ in
            for _ in 0..<Self.rounds { LongTextStats.count(.streamExtends) }
        }
        #expect(LongTextStats.streamExtends - before >= Self.threads * Self.rounds)
    }

    // MARK: Palette

    /// A palette moves one generation per real change, and none for a set of the same value.
    @Test func paletteGenerationMovesOncePerRealChange() {
        let p = Fixture.currentPalette
        #expect(p.next(theme: p.theme, light: p.light) == nil, "the same theme and appearance")
        let flipped = p.next(theme: p.theme, light: !p.light)
        #expect(flipped?.generation == p.generation &+ 1)
        #expect(flipped?.light == !p.light)
        #expect(flipped?.next(theme: p.theme, light: !p.light) == nil, "set again: no second bump")
        #expect(p.next(theme: p.theme, light: p.light, redraw: true)?.generation == p.generation &+ 1, "a colour space change")
    }

    /// A draw off the main thread reads the palette it started with: a change during it (here a colour
    /// space change) does not reach it, so its bitmap is one palette, cached under that generation.
    @Test func anOffMainDrawKeepsThePaletteItStartedWith() async {
        let s: (start: Int, during: Int, current: Int, after: Int) = await withCheckedContinuation { done in
            DispatchQueue(label: "catalyst-shared-state.draw", qos: .userInitiated).async {
                let inside = Fixture.withRenderScale(2) { () -> (Int, Int, Int) in
                    let start = Fixture.paletteGeneration
                    Fixture.colorSpaceChanged()
                    return (start, Fixture.paletteGeneration, Fixture.currentPalette.generation)
                }
                done.resume(returning: (inside.0, inside.1, inside.2, Fixture.paletteGeneration))
            }
        }
        #expect(s.during == s.start, "inside the draw: its own palette")
        #expect(s.current > s.start, "the change is the current palette")
        #expect(s.after >= s.current, "after the draw: the current palette")
    }

    /// The thread view's elevated colours belong to the draw that asks for them: a row drawn on
    /// another thread meanwhile draws the transcript's colours (it was one process flag).
    @Test func elevatedIsTheDrawsOwn() async {
        #expect(!Fixture.elevated)
        let (inside, nested) = Fixture.withRenderScale(0, elevated: true) {
            (Fixture.elevated, Fixture.withRenderScale(2) { Fixture.elevated })
        }
        #expect(inside)
        #expect(nested, "a nested scope keeps it")
        let other: Bool = await withCheckedContinuation { done in
            Fixture.withRenderScale(0, elevated: true) {
                // A row drawn on another thread while this draw is elevated.
                DispatchQueue(label: "catalyst-shared-state.row", qos: .userInitiated).async { done.resume(returning: Fixture.elevated) }
            }
        }
        #expect(!other, "a row on another thread is not elevated")
        #expect(!Fixture.elevated, "the scope ended")
    }

    // MARK: GuardedFetcher

    /// What a fetch ended with (`done` runs once, on the fetcher's queue).
    private final class Outcome: Sendable {
        private let results = OSAllocatedUnfairLock(initialState: [Swift.Result<GuardedFetcher.Result, LinkGuard.Refusal>]())
        var done: GuardedFetcher.Done { { r in self.results.withLock { $0.append(r) } } }
        var all: [Swift.Result<GuardedFetcher.Result, LinkGuard.Refusal>] { results.withLock { $0 } }
        var refusal: LinkGuard.Refusal? {
            guard all.count == 1, case let .failure(r)? = all.first else { return nil }
            return r
        }
        var data: Data? {
            guard all.count == 1, case let .success(page)? = all.first else { return nil }
            return page.data
        }
    }

    // Public IP literals: LinkGuard.check resolves no name for them.
    private static func url(_ s: String) throws -> URL { try #require(URL(string: s)) }
    private static func page() throws -> URL { try url("https://93.184.216.34/a") }
    private static func hop(_ n: Int) throws -> URL { try url("https://93.184.216.34/r\(n)") }

    @Test func aSixthRedirectIsRefused() throws {
        let page = try Self.page()
        let f = GuardedFetcher(), out = Outcome()
        f.track(1, url: page, limit: LinkGuard.htmlLimit, html: true, done: out.done)
        let hops = try (1...LinkGuard.maxRedirects + 1).map(Self.hop)
        for next in hops.dropLast() { #expect(f.redirect(1, to: next) == true) }
        #expect(f.redirect(1, to: hops[LinkGuard.maxRedirects]) == false)
        f.complete(1, error: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled), response: nil)
        #expect(out.refusal == .redirectLimit)
    }

    @Test func anHTTPSToHTTPRedirectIsRefused() throws {
        let page = try Self.page()
        let f = GuardedFetcher(), out = Outcome()
        f.track(1, url: page, limit: LinkGuard.htmlLimit, html: true, done: out.done)
        let plain = try Self.url("http://93.184.216.34/a")
        #expect(f.redirect(1, to: plain) == false)
        f.complete(1, error: nil, response: nil)
        #expect(out.refusal == .downgrade)
    }

    @Test func aRedirectToAPrivateAddressIsRefused() throws {
        let page = try Self.page()
        let f = GuardedFetcher(), out = Outcome()
        f.track(1, url: page, limit: LinkGuard.htmlLimit, html: true, done: out.done)
        let intranet = try Self.url("https://10.0.0.1/admin")
        #expect(f.redirect(1, to: intranet) == false)
        f.complete(1, error: nil, response: nil)
        #expect(out.refusal == .address("10.0.0.1"))
        #expect(f.redirect(2, to: page) == nil, "no such task")
    }

    @Test func anImageOverItsLimitIsRefused() throws {
        let page = try Self.page()
        let f = GuardedFetcher(), declared = Outcome(), streamed = Outcome()
        f.track(1, url: page, limit: 10, html: false, done: declared.done)
        #expect(!f.respond(1, expectedLength: 11), "a declared length over the limit")
        f.complete(1, error: nil, response: nil)
        #expect(declared.refusal == .tooLarge)

        f.track(2, url: page, limit: 10, html: false, done: streamed.done)
        #expect(f.respond(2, expectedLength: -1), "an unknown length reads")
        #expect(!f.receive(2, Data(count: 10)))
        #expect(f.receive(2, Data(count: 1)), "the eleventh byte stops it")
        f.complete(2, error: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled), response: nil)
        #expect(streamed.refusal == .tooLarge)
    }

    /// A page is cut at its limit or at `</head>`, never refused for its length, and our own stop is
    /// not a network error.
    @Test func aPageStopsAtItsHeadEndOrItsLimit() throws {
        let page = try Self.page()
        let f = GuardedFetcher(), head = Outcome(), long = Outcome()
        let cancelled = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        f.track(1, url: page, limit: 64, html: true, done: head.done)
        #expect(f.respond(1, expectedLength: 1 << 20), "a long page is read up to its head")
        #expect(!f.receive(1, Data("<html><head><title>t</title>".utf8)))
        #expect(f.receive(1, Data("</HEAD><body>".utf8)), "past </head>: stop")
        f.complete(1, error: cancelled, response: nil)
        #expect(head.data.map { String(decoding: $0, as: UTF8.self) } == "<html><head><title>t</title></HEAD><body>")

        f.track(2, url: page, limit: 8, html: true, done: long.done)
        #expect(f.receive(2, Data("<html><head>".utf8)), "over the limit: stop")
        f.complete(2, error: cancelled, response: nil)
        #expect(long.data?.count == 8)
    }

    /// The address URLSession connected to is checked again (DNS rebinding), and a refusal already
    /// made stays the one reported.
    @Test func aConnectionToAPrivateAddressDropsTheResponse() throws {
        let page = try Self.page()
        let f = GuardedFetcher(), rebound = Outcome(), first = Outcome()
        f.track(1, url: page, limit: LinkGuard.htmlLimit, html: true, done: rebound.done)
        f.connected(1, to: ["93.184.216.34", "127.0.0.1"])
        f.complete(1, error: nil, response: HTTPURLResponse(url: page, statusCode: 200, httpVersion: nil, headerFields: nil))
        #expect(rebound.refusal == .connectedTo("127.0.0.1"))

        f.track(2, url: page, limit: 10, html: false, done: first.done)
        _ = f.respond(2, expectedLength: 11)
        f.connected(2, to: ["169.254.169.254"])
        f.complete(2, error: nil, response: nil)
        #expect(first.refusal == .tooLarge)
    }

    @Test func aNon2xxStatusIsAFailureAndA200IsThePage() throws {
        let page = try Self.page()
        let f = GuardedFetcher(), missing = Outcome(), ok = Outcome()
        f.track(1, url: page, limit: 64, html: false, done: missing.done)
        f.complete(1, error: nil, response: HTTPURLResponse(url: page, statusCode: 404, httpVersion: nil, headerFields: nil))
        #expect(missing.refusal == .network("HTTP 404"))

        f.track(2, url: page, limit: 64, html: false, done: ok.done)
        _ = f.receive(2, Data("png".utf8))
        f.complete(2, error: nil, response: HTTPURLResponse(url: page, statusCode: 200, httpVersion: nil, headerFields: nil))
        #expect(ok.data == Data("png".utf8))
        f.complete(2, error: nil, response: nil)
        #expect(ok.all.count == 1, "done runs once")
    }
}
