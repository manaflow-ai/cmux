import AppKit
@testable import CmuxNextDesign
import Testing

/// A toast's Details reads in plain words: a known error code in the raw reason becomes a sentence,
/// with the code under it, small and dimmed, to copy into a bug; an unknown one shows the reason as
/// it came (Leo, 2026-11-01, on the expanded "Couldn't update" toast with `fs.no_space` in it:
/// "ok tho the details toast doesnt look very good").
@MainActor
struct CmuxToastDetailCopyTests {
    private static let noSpace = "cannot copy the build to the machine: fs.no_space: no space left on the device"

    @Test func aKnownCodeReadsInPlainWordsWithTheCode() {
        let copy = CmuxToastDetailCopy.plain(Self.noSpace)
        #expect(copy.code == "fs.no_space")
        #expect(copy.text == CmuxToastDetailCopy.words("fs.no_space"))
        #expect(copy.text == "The machine is out of disk space.")
        #expect(!copy.text.contains("fs.no_space"))
        #expect(CmuxToastDetailCopy.codeLine("fs.no_space") == "Error code: fs.no_space")
    }

    @Test func everyMappedCodeHasWords() {
        for code in ["fs.no_space", "disk_full", "fs.read_only", "fs.permission_denied", "fs.too_large"] {
            let copy = CmuxToastDetailCopy.plain("push failed: \(code).")
            #expect(copy.code == code, "\(code)")
            #expect(copy.text.isEmpty == false && copy.text != "push failed: \(code).")
        }
    }

    @Test func anUnknownCodeOrNoneKeepsTheRawDetail() {
        for raw in ["Bootstrap failed: 125: Domain does not support specified action (launchctl bootstrap gui/501)",
                    "the machine answered fs.something_new: who knows",
                    "acpmux exited without a status", ""] {
            #expect(CmuxToastDetailCopy.plain(raw) == CmuxToastDetailCopy(text: raw))
        }
    }

    /// Several lines are several machines' reasons: one sentence would hide all but one.
    @Test func severalLinesKeepTheRawDetail() {
        let raw = "Couldn't update a: \(Self.noSpace)\nCouldn't update b: ssh failed"
        #expect(CmuxToastDetailCopy.plain(raw) == CmuxToastDetailCopy(text: raw))
    }

    /// Expanded with a known code: the title row holds the title, Hide Details and close on one
    /// line at the trailing edge; under it the plain words on their own wrapped block, then the code,
    /// dimmed and selectable, all inside the toast.
    @Test func theExpandedToastLaysOutTitleRowMessageAndCode() throws {
        let view = CmuxToastView(toast: CmuxToast(id: "daemon-update.failures", message: "Couldn't update fs-lane-3",
                                                  detail: Self.noSpace, action: .details("Details"),
                                                  duration: CmuxToast.untilClosed))
        view.layoutSubtreeIfNeeded()
        view.translatesAutoresizingMaskIntoConstraints = true
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        view.setShowsDetails(true)
        view.layoutSubtreeIfNeeded()
        view.setFrameSize(view.fittingSize)
        view.layoutSubtreeIfNeeded()

        let detail = try #require(view.detailLabel)
        let code = try #require(view.codeLabel)
        let button = try #require(view.actionButton)
        let message = try #require(view.messageLabel)
        #expect(detail.stringValue == "The machine is out of disk space.")
        #expect(code.stringValue == "Error code: fs.no_space")
        #expect(code.isSelectable && !code.isHidden)
        #expect(code.themedToolTip == Self.noSpace, "the raw reason is gone")
        #expect((code.font?.pointSize ?? 0) < (detail.font?.pointSize ?? 0), "the code is not secondary")
        #expect(button.accessibilityLabel() == CmuxToastStrings.hideDetails)
        #expect(view.frame.width >= CmuxToastView.expandedMinWidth - 0.5)

        func frame(_ v: NSView) -> NSRect { v.convert(v.bounds, to: view) }
        let titleFrame = frame(message), buttonFrame = frame(button), closeFrame = frame(view.closeButton)
        let detailFrame = frame(detail), codeFrame = frame(code)
        // One title line: Hide Details and close on it, at the trailing edge.
        #expect(abs(buttonFrame.midY - closeFrame.midY) < 0.5)
        #expect(abs(buttonFrame.midY - titleFrame.midY) < 1, "\(buttonFrame) \(titleFrame)")
        #expect(view.bounds.maxX - closeFrame.maxX <= Metrics.space4 + 0.5, "close left the trailing edge: \(closeFrame)")
        #expect(buttonFrame.maxX <= closeFrame.minX)
        // The plain words under the title, the code under them (the view is not flipped).
        #expect(detailFrame.maxY <= titleFrame.minY - Metrics.space2 + 0.5, "\(detailFrame) \(titleFrame)")
        #expect(codeFrame.maxY <= detailFrame.minY + 0.5, "\(codeFrame) \(detailFrame)")
        #expect(abs(detailFrame.minX - titleFrame.minX) < 0.5, "the detail is not aligned with the title")
        for inner in [detailFrame, codeFrame] { #expect(view.bounds.contains(inner), "\(inner) outside \(view.bounds)") }
    }

    /// A long reason with an unknown code wraps as one block at the toast's width, with no code line.
    @Test func aLongUnknownReasonWrapsWithNoCodeLine() throws {
        let long = String(repeating: "ssh build-box: install exited 1 after copying the payload. ", count: 6)
        let view = CmuxToastView(toast: CmuxToast(id: "t", message: "Couldn't update build-box", detail: long,
                                                  action: .details("Details"), duration: CmuxToast.untilClosed))
        view.layoutSubtreeIfNeeded()
        view.setShowsDetails(true)
        view.layoutSubtreeIfNeeded()
        let detail = try #require(view.detailLabel)
        #expect(view.codeLabel == nil)
        #expect(detail.stringValue == long)
        #expect(detail.fittingSize.height > Typography.body.pointSize * 2, "the long reason did not wrap")
        #expect(view.fittingSize.width < CmuxToastView.expandedMinWidth + 200, "the long reason widened the toast")
    }
}
