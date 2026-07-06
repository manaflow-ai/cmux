import CoreGraphics
import XCTest

@testable import CmuxWindowing

final class DisplayConfigurationSignatureTests: XCTestCase {
    private func display(
        _ stableID: String?,
        frame: CGRect,
        visibleFrame: CGRect? = nil
    ) -> SessionDisplayGeometry {
        SessionDisplayGeometry(
            displayID: nil,
            stableID: stableID,
            frame: frame,
            visibleFrame: visibleFrame ?? frame
        )
    }

    private let builtIn = CGRect(x: 0, y: 0, width: 1_512, height: 982)
    private let externalAbove = CGRect(x: 0, y: 982, width: 1_920, height: 1_080)

    // MARK: order independence

    func testSignatureIsOrderIndependent() {
        let a = display("uuid:A", frame: builtIn)
        let b = display("uuid:B", frame: externalAbove)
        let s1 = DisplayConfigurationSignature.signature(for: [a, b])
        let s2 = DisplayConfigurationSignature.signature(for: [b, a])
        XCTAssertNotNil(s1)
        XCTAssertEqual(s1, s2)
    }

    // MARK: visibleFrame excluded, frame included

    func testVisibleFrameChangeDoesNotChangeSignature() {
        // Same physical display, Dock shown vs hidden → different visibleFrame,
        // identical frame. Signature must be stable.
        let dockHidden = display("uuid:A", frame: builtIn, visibleFrame: builtIn)
        let dockShown = display(
            "uuid:A",
            frame: builtIn,
            visibleFrame: CGRect(x: 0, y: 70, width: 1_512, height: 912)
        )
        XCTAssertEqual(
            DisplayConfigurationSignature.signature(for: [dockHidden]),
            DisplayConfigurationSignature.signature(for: [dockShown])
        )
    }

    func testResolutionChangeChangesSignature() {
        let hiRes = display("uuid:A", frame: CGRect(x: 0, y: 0, width: 3_840, height: 2_160))
        let loRes = display("uuid:A", frame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080))
        XCTAssertNotEqual(
            DisplayConfigurationSignature.signature(for: [hiRes]),
            DisplayConfigurationSignature.signature(for: [loRes])
        )
    }

    // MARK: identical-panel disambiguation by position

    func testIdenticalPanelsAreDisambiguatedByPosition() {
        // Two identical-EDID monitors share a UUID; only arrangement origin
        // distinguishes them. The two-monitor signature must differ from a
        // single monitor, and left/right layout must be encoded.
        let left = display("uuid:SAME", frame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080))
        let right = display("uuid:SAME", frame: CGRect(x: 1_920, y: 0, width: 1_920, height: 1_080))
        let sig = DisplayConfigurationSignature.signature(for: [left, right])
        XCTAssertNotNil(sig)
        // Distinct from a single monitor of that model.
        XCTAssertNotEqual(sig, DisplayConfigurationSignature.signature(for: [left]))
        // Both positions are represented.
        XCTAssertTrue(sig!.contains("0,0"))
        XCTAssertTrue(sig!.contains("1920,0"))
    }

    // MARK: mirror distinctness

    func testMirrorSignatureNeverCollidesWithLaptopOnly() {
        let laptop = display("uuid:A", frame: builtIn)
        let plain = DisplayConfigurationSignature.signature(for: [laptop], isMirrored: false)
        let mirrored = DisplayConfigurationSignature.signature(for: [laptop], isMirrored: true)
        XCTAssertNotNil(plain)
        XCTAssertNotNil(mirrored)
        XCTAssertNotEqual(plain, mirrored)
    }

    // MARK: refuse to key when no stable identity

    func testNoStableIdentityYieldsNilSignature() {
        let unkeyed = display(nil, frame: builtIn)
        XCTAssertNil(DisplayConfigurationSignature.signature(for: [unkeyed]))
        XCTAssertNil(DisplayConfigurationSignature.signature(for: []))
    }

    func testDisplaysWithoutStableKeyAreExcludedButOthersStillKey() {
        let keyed = display("uuid:A", frame: builtIn)
        let unkeyed = display(nil, frame: externalAbove)
        // The unkeyed display drops out; the signature reflects only the keyed one
        // and equals the single-display signature.
        XCTAssertEqual(
            DisplayConfigurationSignature.signature(for: [keyed, unkeyed]),
            DisplayConfigurationSignature.signature(for: [keyed])
        )
    }

    // MARK: degenerate frames excluded

    func testDegenerateFrameIsExcluded() {
        let ramping = display("uuid:RAMP", frame: CGRect(x: 0, y: 0, width: 0, height: 0))
        XCTAssertNil(DisplayConfigurationSignature.signature(for: [ramping]))

        let nonFinite = display(
            "uuid:NAN",
            frame: CGRect(x: CGFloat.nan, y: 0, width: 1_920, height: 1_080)
        )
        XCTAssertNil(DisplayConfigurationSignature.signature(for: [nonFinite]))
    }

    // MARK: sub-pixel jitter stability

    func testSubPixelJitterDoesNotChangeSignature() {
        let a = display("uuid:A", frame: CGRect(x: 0, y: 0, width: 1_512.0, height: 982.0))
        let b = display("uuid:A", frame: CGRect(x: 0.3, y: -0.2, width: 1_511.6, height: 982.4))
        XCTAssertEqual(
            DisplayConfigurationSignature.signature(for: [a]),
            DisplayConfigurationSignature.signature(for: [b])
        )
    }
}
