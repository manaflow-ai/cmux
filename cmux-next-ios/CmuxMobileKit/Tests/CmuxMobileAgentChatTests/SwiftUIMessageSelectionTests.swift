#if os(iOS)
import CmuxMobileDesign
import CmuxMobileMarkdown
import SwiftUI
import Testing
import UIKit
@testable import CmuxMobileAgentChat

@MainActor
struct SwiftUIMessageSelectionTests {
    /// Exercise the hosted transcript row at an accessibility text size. Each cell of a table
    /// must receive both the local Copy Table and the enclosing message actions.
    @Test func tableCellHasWordSelectionAndBothMenuScopes() throws {
        let message = "| Name | File |\n| --- | --- |\n| Main | `src/app.swift` |"
        try withLabel("src/app.swift", in: message) { label, selector in
            let titles = selector.extraMenu?(label).compactMap { ($0 as? UIAction)?.title }
            #expect(titles == ["Copy Table", "Copy Message", "Select Text", "Share Message"])

            let attributedText = try #require(label.attributedText)
            let attributes = attributedText.attributes(at: 0, effectiveRange: nil)
            let font = try #require(attributes[.font] as? UIFont)
            #expect(font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace))
            #expect(font.pointSize == NativeTextStyles(category: .accessibilityLarge).font(.subheadline).pointSize)
            #expect((attributes[NativeMarkdownLayout.linkKey] as? URL)?.relativeString == "src/app.swift")
        }
    }

    @Test func emptyCodeFenceStillOffersCodeAndMessageActions() throws {
        try withLabel("Swift", in: "```swift\n```") { label, selector in
            let titles = selector.extraMenu?(label).compactMap { ($0 as? UIAction)?.title }
            #expect(titles == ["Copy Code", "Select Code Text", "Copy as Markdown", "Share Code",
                               "Copy Message", "Select Text", "Share Message"])
        }
    }

    private func withLabel(_ title: String, in message: String,
                           check: (UILabel, InPlaceTextSelection) throws -> Void) throws {
        let block = try #require(MarkdownDocument(parsing: message).blocks.first)
        let row = MarkdownBlockRow(block: block, message: { message }).dynamicTypeSize(.accessibility2)
        let controller = UIHostingController(rootView: row)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        controller.view.layoutIfNeeded()

        func textLabel(in view: UIView) -> UILabel? {
            if let label = view as? UILabel, label.text == title { return label }
            for child in view.subviews {
                if let label = textLabel(in: child) { return label }
            }
            return nil
        }

        let label = try #require(textLabel(in: controller.view))
        let host = try #require(label.superview)
        let selector = try #require(host.gestureRecognizers?.compactMap { $0.delegate as? InPlaceTextSelection }.first)
        #expect(selector.label(at: label.center) === label)
        try check(label, selector)
    }
}
#endif
