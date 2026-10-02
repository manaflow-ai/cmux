import AppKit
import CmuxNextBrowserImport
import CmuxNextDesign
import Testing
@testable import CmuxNextOnboarding

/// Onboarding's text buttons and profile rows show a tonal hover and
/// pressed fill from theme tokens, nothing moves when it shows, and a row
/// toggles on release inside it, as a button does. Reduce Motion is pinned
/// both ways: CI runners have it on, the capture minis off.
@MainActor
@Suite(.serialized) struct HoverTests {
    final class Harness {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.borderless], backing: .buffered, defer: true)

        init() {
            window.isReleasedWhenClosed = false
        }

        func host(_ view: NSView, width: CGFloat) {
            window.contentView!.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20),
                view.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20),
                view.widthAnchor.constraint(equalToConstant: width),
            ])
            window.contentView!.layoutSubtreeIfNeeded()
        }

        func event(_ type: NSEvent.EventType, at point: NSPoint, in view: NSView) -> NSEvent {
            let location = view.convert(point, to: nil)
            if type == .mouseEntered || type == .mouseExited {
                return NSEvent.enterExitEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                              trackingNumber: 0, userData: nil)!
            }
            return NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
    }

    final class Sink: NSObject {
        @objc func hit() {}
    }

    /// The fill's alpha as drawn now; 0 when there is none.
    func fillAlpha(_ hover: OnboardingHover) -> CGFloat {
        hover.shownFill?.alpha ?? 0
    }

    func profile() -> BrowserSourceProfile {
        BrowserSourceProfile(browser: .edge, directoryName: "Default", displayName: "Work", path: URL(fileURLWithPath: "/tmp/Default"),
                             availability: [.bookmarks: .available])
    }

    @Test func theFillIsOneTonalStepPerState() {
        #expect(OnboardingHover.fillColor(.init()) == nil)
        #expect(OnboardingHover.fillColor(.init(hovering: true)) == Palette.hoverFill)
        #expect(OnboardingHover.fillColor(.init(hovering: true, pressed: true)) == Palette.pressedFill)
        #expect(OnboardingHover.fillColor(.init(focused: true)) == nil, "focus is an outline, not a fill")
    }

    @Test(arguments: [true, false])
    func aTextButtonHoversWithoutMoving(reduceMotion: Bool) {
        Motion.reduceMotionOverride = reduceMotion
        defer { Motion.reduceMotionOverride = nil }
        let h = Harness()
        defer { h.window.close() }
        let button = OnboardingTextButton("Skip", target: nil, action: #selector(Sink.hit))
        h.window.contentView!.addSubview(button)
        button.setFrameOrigin(NSPoint(x: 20, y: 20))
        button.setFrameSize(button.intrinsicContentSize)
        button.layoutSubtreeIfNeeded()
        let frame = button.frame
        let size = button.intrinsicContentSize
        #expect(fillAlpha(button.hover) == 0)

        button.mouseEntered(with: h.event(.mouseEntered, at: NSPoint(x: 2, y: 2), in: button))
        button.layoutSubtreeIfNeeded()
        #expect(button.hover.state.hovering)
        #expect(fillAlpha(button.hover) > 0)
        #expect(button.frame == frame && button.intrinsicContentSize == size)
        #expect(button.hover.fillFrame.width > button.bounds.width, "the fill reaches past the text, the text does not move")

        button.mouseExited(with: h.event(.mouseExited, at: NSPoint(x: -50, y: -50), in: button))
        #expect(!button.hover.state.hovering)
        #expect(fillAlpha(button.hover) == 0)
    }

    @Test func aDisabledTextButtonShowsNoHover() {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let h = Harness()
        defer { h.window.close() }
        let button = OnboardingTextButton("Back", target: nil, action: #selector(Sink.hit))
        h.window.contentView!.addSubview(button)
        button.isEnabled = false
        button.mouseEntered(with: h.event(.mouseEntered, at: .zero, in: button))
        #expect(!button.hover.state.hovering)
    }

    @Test func aProfileRowTogglesOnReleaseInside() {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let h = Harness()
        defer { h.window.close() }
        var toggles = 0
        let row = ImportProfileRow(profile: profile(), appURL: nil) { toggles += 1 }
        h.host(row, width: 300)
        row.update(checked: true, editable: true, state: .idle)
        let inside = NSPoint(x: 40, y: ImportProfileRow.height / 2)

        row.mouseEntered(with: h.event(.mouseEntered, at: inside, in: row))
        #expect(row.hover.state.hovering)
        row.mouseDown(with: h.event(.leftMouseDown, at: inside, in: row))
        #expect(row.hover.state.pressed && toggles == 0, "pressing shows the pressed fill and does not toggle yet")
        row.mouseUp(with: h.event(.leftMouseUp, at: inside, in: row))
        #expect(!row.hover.state.pressed && toggles == 1)

        row.mouseDown(with: h.event(.leftMouseDown, at: inside, in: row))
        row.mouseUp(with: h.event(.leftMouseUp, at: NSPoint(x: 40, y: 500), in: row))
        #expect(toggles == 1, "releasing outside the row cancels")
    }

    @Test func aRowThatCannotChangeShowsNoHover() {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let h = Harness()
        defer { h.window.close() }
        var toggles = 0
        let row = ImportProfileRow(profile: profile(), appURL: nil) { toggles += 1 }
        h.host(row, width: 300)
        row.update(checked: true, editable: false, state: .waiting)
        let inside = NSPoint(x: 40, y: ImportProfileRow.height / 2)
        row.mouseEntered(with: h.event(.mouseEntered, at: inside, in: row))
        row.mouseDown(with: h.event(.leftMouseDown, at: inside, in: row))
        row.mouseUp(with: h.event(.leftMouseUp, at: inside, in: row))
        #expect(row.hover.state == OnboardingHover.State() && toggles == 0)
    }

    @Test func aCheckRowHoversPastItsEdgesAndClicksItsBox() {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let h = Harness()
        defer { h.window.close() }
        let box = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        box.translatesAutoresizingMaskIntoConstraints = false
        let row = ImportCheckRow(title: "Chrome", font: OnboardingMetrics.bodyFont, box: box, separated: false)
        h.host(row, width: 300)
        let inside = NSPoint(x: 20, y: 20)
        row.mouseEntered(with: h.event(.mouseEntered, at: inside, in: row))
        #expect(row.hover.state.hovering)
        #expect(row.hover.fillFrame.minX < 0 && row.hover.fillFrame.maxX > row.bounds.maxX)
        row.mouseDown(with: h.event(.leftMouseDown, at: inside, in: row))
        row.mouseUp(with: h.event(.leftMouseUp, at: inside, in: row))
        #expect(box.state == .on)
    }
}
