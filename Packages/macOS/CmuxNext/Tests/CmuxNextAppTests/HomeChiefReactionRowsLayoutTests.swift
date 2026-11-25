import AppKit
import CmuxNextDesign
@testable import CmuxNextDaemon
@testable import CmuxNextHomeEngine
import CmuxNextTestSupport
import Foundation
import Testing

/// The Chief Settings card's Reactions block lays out without cut-off titles and draws the room's
/// theme (a416 follow-up: the first picture showed "Can Wake the…" and "Classifier Har…", and its light
/// half drew dark field boxes). Each title shows whole at the card's width, and in a light room the
/// classifier's field boxes take the theme's light field fill (`Palette.chromeBackground`).
@MainActor @Suite(.serialized, .closesItsWindows) struct HomeChiefReactionRowsLayoutTests {
    static func scope(dark: Bool) -> ThemeScope {
        let scope = ThemeScope(level: .room)
        let input = dark
            ? ThemeInput(background: ThemeRGB(hex: 0x1E1E1E), foreground: ThemeRGB(hex: 0xD4D4D4))
            : ThemeInput(background: ThemeRGB(hex: 0xFFFFFF), foreground: ThemeRGB(hex: 0x24292F))
        scope.setOverride(ThemeSpec("Neutral"), input: input, animated: false)
        return scope
    }

    /// The card at its width in a window (as the popover shows it), rooted in `scope`, the
    /// Classifier disclosure open. The window is returned so the caller keeps it alive.
    static func card(in scope: ThemeScope) async -> (HomeChiefSettingsView, NSWindow) {
        let view = HomeChiefSettingsView(muxHome: FileManager.default.temporaryDirectory, source: LayoutChief())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: HomeChiefSettingsView.width, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        scope.root(view)
        await view.refresh().value
        view.reactionRows.showsClassifier = true
        window.setContentSize(NSSize(width: HomeChiefSettingsView.width, height: view.fittingSize.height))
        view.layoutSubtreeIfNeeded()
        return (view, window)
    }

    static func labels(in view: NSView) -> [ChromeLabel] {
        var found: [ChromeLabel] = []
        if let label = view as? ChromeLabel, !label.stringValue.isEmpty, !label.isHidden { found.append(label) }
        for subview in view.subviews { found += labels(in: subview) }
        return found
    }

    @Test func everyReactionsTitleShowsWhole() async {
        let (view, window) = await Self.card(in: Self.scope(dark: false))
        defer { window.close() }
        let labels = Self.labels(in: view.reactionRows)
        #expect(labels.count >= 4)
        for label in labels {
            let text = label.attributedStringValue
            let needed = label.wraps
                ? text.boundingRect(with: NSSize(width: label.frame.width, height: .greatestFiniteMagnitude),
                                    options: [.usesLineFragmentOrigin, .usesFontLeading]).size
                : text.size()
            #expect(needed.width.rounded(.up) <= label.frame.width + 0.5 && needed.height.rounded(.up) <= label.frame.height + 1,
                    "\"\(label.stringValue)\" is cut off: needs \(needed), has \(label.frame.size)")
        }
    }

    @Test(arguments: [false, true]) func theFieldBoxesDrawTheRoomsFieldFill(dark: Bool) async throws {
        let scope = Self.scope(dark: dark)
        let (view, window) = await Self.card(in: scope)
        defer { window.close() }
        let fill = scope.perform { Palette.chromeBackground }
        let boxes = [view.reactionRows.harness, view.reactionRows.model, view.reactionRows.prompt].compactMap { $0.superview as? ThemedFieldBox }
        #expect(boxes.count == 3)
        for box in boxes {
            let color = try #require(box.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))?.usingColorSpace(.sRGB))
            let want = try #require(fill.usingColorSpace(.sRGB))
            #expect(abs(color.redComponent - want.redComponent) < 0.02 && abs(color.greenComponent - want.greenComponent) < 0.02
                    && abs(color.blueComponent - want.blueComponent) < 0.02, "\(dark ? "dark" : "light"): \(color) is not \(want)")
            let luminance = 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
            #expect(dark ? luminance < 0.5 : luminance > 0.5, "\(dark ? "dark" : "light") room, field luminance \(luminance)")
        }
    }
}

/// A brain that resolved the classifier defaults.
private struct LayoutChief: HomeChiefEngineSource {
    var isLocal: Bool { true }
    var place: String? { nil }
    var snapshot: HomeChiefSnapshot {
        var snapshot = HomeChiefSnapshot(harness: "claude", model: nil, effort: nil, avatar: nil, turns: [])
        snapshot.effective = HomeChiefReactionRowsTests.resolved
        return snapshot
    }
    func read() async throws(HomeChiefEngineError) -> HomeChiefSnapshot { snapshot }
    func set(_ fields: [String: String?]) async throws(HomeChiefEngineError) -> HomeChiefSnapshot { snapshot }
}
