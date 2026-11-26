import CoreGraphics
import Testing

@testable import CmuxWindowing

@Suite
struct DisplayConfigurationSignatureTests {
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

    @Test
    func signatureIsOrderIndependent() {
        let a = display("uuid:A", frame: builtIn)
        let b = display("uuid:B", frame: externalAbove)
        let s1 = [a, b].displayConfigurationSignature()
        let s2 = [b, a].displayConfigurationSignature()
        #expect(s1 != nil)
        #expect(s1 == s2)
    }

    // MARK: visibleFrame excluded, frame included

    @Test
    func visibleFrameChangeDoesNotChangeSignature() {
        // Same physical display, Dock shown vs hidden → different visibleFrame,
        // identical frame. Signature must be stable.
        let dockHidden = display("uuid:A", frame: builtIn, visibleFrame: builtIn)
        let dockShown = display(
            "uuid:A",
            frame: builtIn,
            visibleFrame: CGRect(x: 0, y: 70, width: 1_512, height: 912)
        )
        #expect([dockHidden].displayConfigurationSignature() == [dockShown].displayConfigurationSignature())
    }

    @Test
    func resolutionChangeChangesSignature() {
        let hiRes = display("uuid:A", frame: CGRect(x: 0, y: 0, width: 3_840, height: 2_160))
        let loRes = display("uuid:A", frame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080))
        #expect([hiRes].displayConfigurationSignature() != [loRes].displayConfigurationSignature())
    }

    // MARK: identical-panel disambiguation by position

    @Test
    func identicalPanelsAreDisambiguatedByPosition() throws {
        // Two identical-EDID monitors share a UUID; only arrangement origin
        // distinguishes them. The two-monitor signature must differ from a
        // single monitor, and left/right layout must be encoded.
        let left = display("uuid:SAME", frame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080))
        let right = display("uuid:SAME", frame: CGRect(x: 1_920, y: 0, width: 1_920, height: 1_080))
        let sig = [left, right].displayConfigurationSignature()
        let signature = try #require(sig)
        // Distinct from a single monitor of that model.
        #expect(signature != [left].displayConfigurationSignature())
        // Both positions are represented.
        #expect(signature.contains("0,0"))
        #expect(signature.contains("1920,0"))
    }

    // MARK: mirror distinctness

    @Test
    func mirrorSignatureNeverCollidesWithLaptopOnly() {
        let laptop = display("uuid:A", frame: builtIn)
        let plain = [laptop].displayConfigurationSignature(isMirrored: false)
        let mirrored = [laptop].displayConfigurationSignature(isMirrored: true)
        #expect(plain != nil)
        #expect(mirrored != nil)
        #expect(plain != mirrored)
    }

    // MARK: refuse to key when no stable identity

    @Test
    func noStableIdentityYieldsNilSignature() {
        let unkeyed = display(nil, frame: builtIn)
        #expect([unkeyed].displayConfigurationSignature() == nil)
        #expect([].displayConfigurationSignature() == nil)
    }

    @Test
    func partialStableIdentityYieldsNilSignature() {
        let keyed = display("uuid:A", frame: builtIn)
        let unkeyed = display(nil, frame: externalAbove)
        #expect([keyed, unkeyed].displayConfigurationSignature() == nil)
        #expect([keyed].displayConfigurationSignature() != nil)
    }

    // MARK: degenerate frames excluded

    @Test
    func degenerateFrameIsExcluded() {
        let ramping = display("uuid:RAMP", frame: CGRect(x: 0, y: 0, width: 0, height: 0))
        #expect([ramping].displayConfigurationSignature() == nil)

        let nonFinite = display(
            "uuid:NAN",
            frame: CGRect(x: CGFloat.nan, y: 0, width: 1_920, height: 1_080)
        )
        #expect([nonFinite].displayConfigurationSignature() == nil)
    }

    // MARK: sub-pixel jitter stability

    @Test
    func subPixelJitterDoesNotChangeSignature() {
        let a = display("uuid:A", frame: CGRect(x: 0, y: 0, width: 1_512.0, height: 982.0))
        let b = display("uuid:A", frame: CGRect(x: 0.3, y: -0.2, width: 1_511.6, height: 982.4))
        #expect([a].displayConfigurationSignature() == [b].displayConfigurationSignature())
    }
}
