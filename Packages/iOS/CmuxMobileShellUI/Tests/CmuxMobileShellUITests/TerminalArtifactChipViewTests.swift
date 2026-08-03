#if os(iOS)
import Testing
import UIKit
@testable import CmuxMobileShellUI

@Suite("Native terminal artifact chip")
struct TerminalArtifactChipViewTests {
    @Test @MainActor
    func exposesLocalizedCountAndPrimaryAction() {
        var tapped = false
        let chip = TerminalArtifactChipView(count: 1) {
            tapped = true
        }

        #expect(chip.accessibilityIdentifier == "MobileTerminalArtifactChip")
        #expect(chip.accessibilityValue?.contains("1") == true)
        #expect(chip.accessibilityTraits.contains(.button))

        chip.update(count: 12)
        #expect(chip.accessibilityValue?.contains("12") == true)

        chip.sendActions(for: .primaryActionTriggered)
        #expect(tapped)

        let size = chip.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        #expect(size.height >= 44)
        #expect(size.width > 44)
    }
}
#endif
