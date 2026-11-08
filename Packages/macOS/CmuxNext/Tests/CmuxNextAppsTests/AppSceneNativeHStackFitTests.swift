import AppKit
@testable import CmuxNextApps
import CmuxNextDesign
import Testing

/// A crowded `HStack` in a native section (the threads template's meta line: a step, a spacer and the
/// agent's name). The native renderer took width from the last text first, so a short trailing label
/// ("claude") wrapped one letter per line while the long step kept its width. It now honors the kit's
/// `fixedSize("horizontal")` (that text never gives width) and `layoutPriority` (lower gives first), as
/// the SwiftUI renderer does.
@MainActor @Suite(.serialized) struct AppSceneNativeHStackFitTests {
    private static let step = "Asking to run the database migration on staging"

    private static func meta(trailing: [String: AppJSON]) -> AppSceneModel {
        let model = AppSceneModel()
        let name: [String: AppJSON] = ["text": "claude", "font": "caption"].merging(trailing) { _, new in new }
        model.apply([
            .create(id: "row", type: "HStack", props: ["spacing": 6]),
            .create(id: "step", type: "Text", props: ["text": .string(step), "font": "caption", "lineLimit": 1, "truncation": "middle"]),
            .create(id: "gap", type: "Spacer", props: [:]),
            .create(id: "name", type: "Text", props: name),
            .children(id: "row", children: ["step", "gap", "name"]),
            .root(id: "row"),
        ])
        return model
    }

    private static func labels(_ model: AppSceneModel, width: CGFloat) -> (step: ChromeLabel, name: ChromeLabel, NSWindow)? {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = AppSceneHostingView(model: model, bundleDirectory: nil)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 100)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let labels = all(hosting).compactMap { $0 as? ChromeLabel }
        guard let step = labels.first(where: { $0.stringValue == Self.step }),
              let name = labels.first(where: { $0.stringValue == "claude" }) else { return nil }
        return (step, name, window)
    }

    private static func natural(_ label: ChromeLabel) -> CGFloat { ceil(label.attributedStringValue.size().width) }

    @Test(arguments: [["fixedSize": "horizontal"], ["layoutPriority": 1]] as [[String: AppJSON]])
    func theTrailingNameKeepsItsWidthAndTheStepTruncates(_ trailing: [String: AppJSON]) throws {
        let (step, name, window) = try #require(Self.labels(Self.meta(trailing: trailing), width: 170))
        defer { window.contentView = nil; window.close() }
        #expect(name.frame.width >= Self.natural(name) - 1, "the name keeps its one line: \(name.frame.width) < \(Self.natural(name))")
        #expect(step.frame.width < Self.natural(step), "the step gives the width and truncates")
        #expect(step.frame.width > 0)
    }

    @Test func withoutEitherTheLastTextStillGivesFirst() throws {
        let (_, name, window) = try #require(Self.labels(Self.meta(trailing: [:]), width: 170))
        defer { window.contentView = nil; window.close() }
        #expect(name.frame.width < Self.natural(name), "unchanged default: the last text gives width first")
    }
}
