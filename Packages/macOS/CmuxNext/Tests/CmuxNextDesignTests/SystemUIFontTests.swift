import AppKit
@testable import CmuxNextDesign
import Testing

/// Chrome text draws in the macOS system font (SF Pro), not a bundled face. Lawrence 2026-11-07: "default fonts on
/// cmux for everything should be macos default, not inter, this applies to everything". `Typography.system`'s
/// default design is the one way chrome gets a UI font, so its family is every chrome label's family.
@MainActor @Suite struct SystemUIFontTests {
    private let systemFamily = NSFont.systemFont(ofSize: 13).familyName

    @Test(arguments: [CGFloat(11), 12, 13, 14, 15, 20])
    func theDefaultDesignIsTheSystemFontAtEveryStep(size: CGFloat) {
        for weight in [NSFont.Weight.regular, .medium, .semibold, .bold] {
            let font = Typography.system(.default, size: size, weight: weight)
            #expect(font.familyName == systemFamily, "\(size) pt \(weight.rawValue): \(font.familyName ?? "nil")")
            #expect(font.familyName?.localizedCaseInsensitiveContains("Inter") == false)
        }
    }

    @Test func namedStylesDrawInTheSystemFont() {
        for font in [Typography.body, Typography.bodyEmphasized, Typography.tabTitle] {
            #expect(font.familyName == systemFamily)
        }
    }

    @Test func monospacedDesignsStayTheSystemMonospacedFont() {
        let mono = Typography.system(.monospaced, size: 12)
        #expect(mono.familyName == NSFont.monospacedSystemFont(ofSize: 12, weight: .regular).familyName)
    }
}
