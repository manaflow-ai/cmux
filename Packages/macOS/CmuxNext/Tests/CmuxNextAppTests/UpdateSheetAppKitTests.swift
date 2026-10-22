import AppKit
@testable import CmuxNextUpdater
import Observation
import Testing

/// The update sheet is AppKit (plans/cmux-next/no-swiftui-DESIGN.md): its body shows the
/// source's title, detail and buttons, a button press reaches the source (and a dismissing one
/// closes the sheet), and a content change redraws the body in place. No SwiftUI bridge.
@MainActor @Suite(.serialized)
struct UpdateSheetAppKitTests {
    @MainActor @Observable
    final class FakeSource: UpdateSheetSource {
        var content: UpdateSheetContent?
        private(set) var pressed: [UpdateSheetButton] = []

        init(_ content: UpdateSheetContent?) { self.content = content }

        func perform(_ button: UpdateSheetButton) { pressed.append(button) }
    }

    private static func subviews(of root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + subviews(of: $0) }
    }

    @Test func theBodyShowsTheContentAndItsButtonsPressTheSource() throws {
        _ = NSApplication.shared
        let source = FakeSource(UpdateSheetContent(symbol: "arrow.down.circle", title: "Update ready", detail: "Version 2",
                                                   buttons: [.later, .install]))
        let controller = UpdateSheetController(source: source)
        controller.present(in: nil)
        defer { controller.dismiss() }
        let body = try #require(controller.bodyView)
        #expect(!hostsSwiftUI(body), "no SwiftUI bridge")
        let labels = Self.subviews(of: body).compactMap { $0.accessibilityLabel() }
        #expect(labels.contains("Update ready"))
        #expect(labels.contains("Version 2"))
        let install = try #require(Self.subviews(of: body).first { $0.accessibilityIdentifier() == "cmux.update.button.install" } as? NSButton)
        install.performClick(nil)
        #expect(source.pressed == [.install])
        #expect(controller.isPresented, "Install does not close the sheet")
        let later = try #require(Self.subviews(of: body).first { $0.accessibilityIdentifier() == "cmux.update.button.later" } as? NSButton)
        later.performClick(nil)
        #expect(source.pressed == [.install, .later])
        #expect(!controller.isPresented, "Later closes the sheet")
    }

    @Test func aContentChangeRedrawsTheBody() throws {
        _ = NSApplication.shared
        let source = FakeSource(UpdateSheetContent(symbol: "arrow.triangle.2.circlepath", title: "Checking", progress: .indeterminate,
                                                   buttons: [.done]))
        let controller = UpdateSheetController(source: source)
        controller.present(in: nil)
        defer { controller.dismiss() }
        let body = try #require(controller.bodyView)
        #expect(Self.subviews(of: body).contains { $0.accessibilityIdentifier() == "cmux.update.progress" })
        source.content = UpdateSheetContent(symbol: "checkmark.circle", title: "Up to date", buttons: [.done])
        controller.reload()
        let labels = Self.subviews(of: body).compactMap { $0.accessibilityLabel() }
        #expect(labels.contains("Up to date"))
        #expect(!labels.contains("Checking"))
        #expect(!Self.subviews(of: body).contains { $0.accessibilityIdentifier() == "cmux.update.progress" })
    }
}

/// Whether `root`'s own view tree (not the inside of an AppKit control, whose private views on
/// macOS 26 include hosting views of AppKit's own) holds a SwiftUI hosting bridge.
@MainActor
private func hostsSwiftUI(_ root: NSView) -> Bool {
    if String(describing: type(of: root)).contains("Hosting") { return true }
    if root is NSControl { return false }
    return root.subviews.contains { hostsSwiftUI($0) }
}
