import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
import CmuxNextHome
import CmuxNextTestSupport
import Testing

/// The labels a pane width change draws again, by name (Lawrence 2026-11-11: "when i resize panes ... it doesnt have
/// smooth animation, check all pane types, all must have smooth transition"). In a sample of a key resize of a Home
/// with 500 rows, `ChromeLabel.updateLayer` was 38 of the 189 samples of the frame's commit, and each label the step
/// measured or resized was in a hidden view. A label whose text and lines stay draws nothing in a width change.
@MainActor enum LabelRedraws {
    static func labels(in view: NSView) -> [ChromeLabel] {
        var found: [ChromeLabel] = []
        func walk(_ view: NSView) {
            if let label = view as? ChromeLabel { found.append(label) }
            view.subviews.forEach(walk)
        }
        walk(view)
        return found
    }

    /// The label's text, whether it shows, and the three views above it.
    static func name(_ label: ChromeLabel) -> String {
        var owners: [String] = []
        var up = label.superview
        while let view = up, owners.count < 3 {
            owners.append(String(describing: type(of: view)))
            up = view.superview
        }
        let hidden = label.isHiddenOrHasHiddenAncestor ? " (hidden)" : ""
        return "\"\(label.stringValue.prefix(28))\"\(hidden) in \(owners.joined(separator: " < "))"
    }

    /// Lays the window out and displays it, as a frame of the app does.
    static func show(_ window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
        window.contentView?.displayIfNeeded()
        CATransaction.flush()
    }

    /// Gives `pane` each width in turn with `pass` after each, and names every label below it that drew its glyphs
    /// again. `drewAtFirst` is how many labels had drawn before the first width (0: the test's display pass draws no
    /// label, so it proves nothing).
    static func redrawn(in pane: NSView, widths: [CGFloat], pass: () -> Void) -> (names: [String], drewAtFirst: Int) {
        pass()
        let all = labels(in: pane)
        let before = all.map(\.glyphDraws)
        for width in widths {
            pane.setFrameSize(NSSize(width: width, height: pane.frame.height))
            pane.needsLayout = true
            pass()
        }
        let names = zip(all, before).compactMap { label, count in
            label.glyphDraws > count ? "\(label.glyphDraws - count)x \(name(label))" : nil
        }
        return (names, before.count(where: { $0 > 0 }))
    }

    static func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        root.wantsLayer = true
        window.contentView = root
        window.orderFrontRegardless()
        return window
    }

    /// Pane widths of a key resize, as in the samples (547 to 821 pt), each above the first-run column's 388 pt.
    static let widths: [CGFloat] = [800, 760, 700, 640, 580, 560]
}

@MainActor @Suite(.serialized, .closesItsWindows) struct HomeResizeChromeWasteTests {
    private func home(in window: NSWindow) -> (AppServices, HomeHostView) {
        let (services, _) = HomeLaunchRevealTests.services()
        let home = HomeHostView(services: services, conversation: "conv_local")
        home.frame = NSRect(x: 0, y: 0, width: 820, height: 700)
        window.contentView?.addSubview(home)
        return (services, home)
    }

    /// The reason Home is unavailable is hidden while Home is available: a width change does not measure it.
    @Test func theHiddenUnavailableMessageIsNotMeasuredInAWidthChange() throws {
        let window = LabelRedraws.window()
        let (services, home) = home(in: window)
        defer { withExtendedLifetime(services) { window.closeAfterTest() } }
        home.layoutSubtreeIfNeeded()
        let message = try #require(home.subviews.compactMap { $0 as? HomeUnavailableLabel }.first, "SETUP: Home has its message label")
        #expect(message.isHidden, "SETUP: the message is hidden until the owner refuses")
        let before = message.measures
        for width in LabelRedraws.widths {
            home.setFrameSize(NSSize(width: width, height: 700))
            home.needsLayout = true
            home.layoutSubtreeIfNeeded()
        }
        #expect(message.measures == before, "a hidden message is not measured in a width change")
        message.isHidden = false
        home.needsLayout = true
        home.layoutSubtreeIfNeeded()
        #expect(message.measures == before + 1, "it is measured when it shows")
        #expect(message.frame.width == home.bounds.width - 48, "at the width of the pane it shows in: \(message.frame) in \(home.bounds)")
    }

    /// The empty Home (its first-run panel shows): a width change that keeps the panel's column draws no label again.
    @Test func aWidthChangeOfTheEmptyHomeDrawsNoLabelAgain() {
        let window = LabelRedraws.window()
        let (services, home) = home(in: window)
        defer { withExtendedLifetime(services) { window.closeAfterTest() } }
        let result = LabelRedraws.redrawn(in: home, widths: LabelRedraws.widths) { LabelRedraws.show(window) }
        #expect(result.drewAtFirst > 0, "SETUP: this test's display pass draws labels (\(LabelRedraws.labels(in: home).count) below Home)")
        #expect(result.names.isEmpty, "labels drawn again in 6 width changes of the empty Home: \(result.names.joined(separator: "; "))")
    }
}
