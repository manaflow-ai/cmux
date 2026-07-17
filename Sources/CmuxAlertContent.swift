import AppKit

/// A modal-alert body that keeps fixed explanatory copy separate from
/// user-sized details.
struct CmuxAlertContent: Equatable, Sendable {
    private static let maximumFixedTextHeightFraction: CGFloat = 0.2

    let informativeText: String
    let scrollableDetails: String?
    let flattenedText: String

    init(informativeText: String) {
        self.informativeText = informativeText
        scrollableDetails = nil
        flattenedText = informativeText
    }

    init(flattenedText: String, separatingScrollableDetails details: String) {
        self.flattenedText = flattenedText

        guard !details.isEmpty,
              let range = flattenedText.range(of: details, options: .backwards) else {
            informativeText = ""
            scrollableDetails = flattenedText
            return
        }

        var summary = flattenedText
        summary.removeSubrange(range)
        while summary.contains("\n\n\n") {
            summary = summary.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        informativeText = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        scrollableDetails = details
    }

    static func scrollingAll(_ text: String) -> Self {
        Self(flattenedText: text, separatingScrollableDetails: text)
    }

    @MainActor
    func apply(to alert: NSAlert, presentingWindow: NSWindow?) {
        let visibleFrame = (presentingWindow?.screen ?? alert.window.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        apply(to: alert, visibleFrame: visibleFrame)
    }

    @MainActor
    func apply(to alert: NSAlert, visibleFrame: NSRect) {
        if let scrollableDetails, !scrollableDetails.isEmpty {
            let flattenedMeasurement = CmuxAlertScrollableDetailsView(
                text: flattenedText,
                visibleFrame: visibleFrame
            )
            guard flattenedMeasurement.isContentHeightCapped else {
                alert.informativeText = flattenedText
                return
            }

            guard !informativeText.isEmpty else {
                alert.informativeText = ""
                alert.accessoryView = flattenedMeasurement
                return
            }

            let summaryMeasurement = CmuxAlertScrollableDetailsView(
                text: informativeText,
                visibleFrame: visibleFrame
            )
            if summaryMeasurement.contentHeight > visibleFrame.height * Self.maximumFixedTextHeightFraction {
                alert.informativeText = ""
                alert.accessoryView = flattenedMeasurement
                return
            }
            alert.informativeText = informativeText
            alert.accessoryView = CmuxAlertScrollableDetailsView(
                text: scrollableDetails,
                visibleFrame: visibleFrame
            )
            return
        }

        let overflowView = CmuxAlertScrollableDetailsView(
            text: informativeText,
            visibleFrame: visibleFrame
        )
        if overflowView.isContentHeightCapped {
            alert.informativeText = ""
            alert.accessoryView = overflowView
        } else {
            alert.informativeText = informativeText
        }
    }
}
