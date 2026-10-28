import CoreGraphics
import Foundation
import Testing
@testable import CmuxMobileTerminal

/// T-SCROLL-12: in a full-screen app the page is pinned and a vertical drag
/// scrolls the app, like a Mac trackpad in Ghostty. The phone turns the drag
/// into precise wheel deltas in points (natural direction: a finger moving
/// down scrolls toward older content) and a fling into momentum deltas that
/// decay; the surface scales them to pixels and Ghostty decides what the app
/// receives (wheel reports or arrows).
@Suite struct TerminalTUIScrollTests {
    typealias Wheel = TerminalTUIScroll.Wheel

    @Test func aDragDownIsAWheelUp() {
        var scroll = TerminalTUIScroll()
        scroll.began()
        #expect(scroll.moved(translationY: 10) == Wheel(dy: 10, momentum: .none))
        // Deltas, not the running translation.
        #expect(scroll.moved(translationY: 14) == Wheel(dy: 4, momentum: .none))
        #expect(scroll.moved(translationY: 4) == Wheel(dy: -10, momentum: .none))
    }

    @Test func noMovementSendsNothing() {
        var scroll = TerminalTUIScroll()
        scroll.began()
        #expect(scroll.moved(translationY: 0) == nil)
        _ = scroll.moved(translationY: 5)
        #expect(scroll.moved(translationY: 5) == nil)
    }

    @Test func aNewDragStartsFromZero() {
        var scroll = TerminalTUIScroll()
        scroll.began()
        _ = scroll.moved(translationY: 50)
        scroll.began()
        #expect(scroll.moved(translationY: -5) == Wheel(dy: -5, momentum: .none))
    }

    @Test func scrollModsArePreciseAndCarryTheMomentumPhase() {
        // Ghostty's packed ScrollMods: bit 0 precision, bits 1-3 momentum.
        #expect(TerminalTUIScroll.mods(.none) == 0b0001)
        #expect(TerminalTUIScroll.mods(.began) == 0b0011)
        #expect(TerminalTUIScroll.mods(.changed) == 0b0111)
        #expect(TerminalTUIScroll.mods(.ended) == 0b1001)
    }

    @Test func onlyAVerticalDragScrollsTheApp() {
        #expect(TerminalTUIScroll.takesDrag(motion: CGPoint(x: 10, y: 200)))
        #expect(TerminalTUIScroll.takesDrag(motion: CGPoint(x: 0, y: -80)))
        #expect(!TerminalTUIScroll.takesDrag(motion: CGPoint(x: 300, y: 40)))
        #expect(!TerminalTUIScroll.takesDrag(motion: .zero))
    }

    /// TUI fast scroll: like a Mac trackpad, a fast finger moves the wheel
    /// further than the finger; a slow one stays 1:1 (line by line).
    @Test func aSlowDragStaysOneToOne() {
        var scroll = TerminalTUIScroll()
        scroll.began()
        #expect(scroll.moved(translationY: 10, velocityY: 150) == Wheel(dy: 10, momentum: .none))
        #expect(scroll.moved(translationY: 4, velocityY: -TerminalTUIScroll.preciseSpeed) == Wheel(dy: -6, momentum: .none))
    }

    @Test func aFastDragScrollsFurtherThanTheFinger() throws {
        var scroll = TerminalTUIScroll()
        scroll.began()
        let movedWheel = scroll.moved(translationY: 16, velocityY: 3000)
        let wheel = try #require(movedWheel)
        #expect(wheel.dy == 16 * TerminalTUIScroll.maximumGain)
        let upWheel = scroll.moved(translationY: 0, velocityY: -3000)
        let up = try #require(upWheel)
        #expect(up.dy == -16 * TerminalTUIScroll.maximumGain)
    }

    @Test func theGainRisesWithSpeedAndIsCapped() {
        let gain = TerminalTUIScroll.gain(speed:)
        #expect(gain(0) == 1)
        #expect(gain(TerminalTUIScroll.preciseSpeed) == 1)
        #expect(gain(-TerminalTUIScroll.fullSpeed) == TerminalTUIScroll.maximumGain)
        #expect(gain(20_000) == TerminalTUIScroll.maximumGain)
        #expect(TerminalTUIScroll.maximumGain >= 2)
        var last: CGFloat = 1
        for speed in stride(from: CGFloat(0), through: 4000, by: 100) {
            #expect(gain(speed) >= last)
            last = gain(speed)
        }
    }

    @Test func aFastFlickGlidesWithTheGain() throws {
        var momentum = try #require(TerminalTUIMomentum(velocityY: 3000))
        let firstWheel = momentum.step(dt: 1.0 / 60)
        let first = try #require(firstWheel)
        #expect(abs(first.dy - 3000 * TerminalTUIScroll.maximumGain * 0.95 / 60) < 0.001)
    }

    @Test func aGentleFlickIsNotScaled() throws {
        var momentum = try #require(TerminalTUIMomentum(velocityY: -250))
        let firstWheel = momentum.step(dt: 1.0 / 60)
        let first = try #require(firstWheel)
        #expect(abs(first.dy - (-250 * 0.95 / 60)) < 0.001)
    }

    @Test func aSlowReleaseHasNoMomentum() {
        #expect(TerminalTUIMomentum(velocityY: 30) == nil)
    }

    @Test func aFlingDecaysAndEnds() throws {
        var momentum = try #require(TerminalTUIMomentum(velocityY: -1200))
        let step = momentum.step(dt: 1.0 / 60)
        let first = try #require(step)
        #expect(first.momentum == .began)
        // Upward fling: newer content, so a wheel down (negative dy).
        #expect(first.dy < 0)
        // 1200 pt/s with its gain, decayed once over one 60 Hz frame.
        #expect(abs(first.dy - (-1200 * TerminalTUIScroll.gain(speed: 1200) * 0.95 / 60)) < 0.001)
        var last = first
        var steps = 1
        while let wheel = momentum.step(dt: 1.0 / 60) {
            #expect(abs(wheel.dy) <= abs(last.dy) || wheel.momentum == .ended)
            last = wheel
            steps += 1
            if wheel.momentum == .ended { break }
            #expect(wheel.momentum == .changed)
            #expect(steps < 1000)
        }
        #expect(last == Wheel(dy: 0, momentum: .ended))
        #expect(momentum.isFinished)
        #expect(momentum.step(dt: 1.0 / 60) == nil)
    }

    @Test func stoppingAFlingEndsItOnce() throws {
        var momentum = try #require(TerminalTUIMomentum(velocityY: 900))
        _ = momentum.step(dt: 1.0 / 60)
        #expect(momentum.stop() == Wheel(dy: 0, momentum: .ended))
        #expect(momentum.stop() == nil)
        #expect(momentum.step(dt: 1.0 / 60) == nil)
    }

    @Test func aStoppedFlingThatNeverBeganSendsNothing() throws {
        var momentum = try #require(TerminalTUIMomentum(velocityY: 900))
        #expect(momentum.stop() == nil)
    }
}
