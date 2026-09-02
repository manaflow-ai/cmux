import Foundation

/// Separates rendered-content revisions from exact frame-emission identities.
///
/// ``renderRevision`` is a stable polling token: it advances when the visible
/// grid or its dimensions change, and it does not advance when the same frame
/// is replayed. ``emissionRevision`` advances for every frame the producer
/// emits, including an unchanged replay, so delta consumers can still prove
/// that their base is the exact frame the producer diffed against.
public struct MobileTerminalRenderGridRevisionTracker: Sendable {
    /// The producer identity attached to one emitted frame.
    public struct Identity: Equatable, Sendable {
        /// Producer lifetime. A new terminal runtime starts a new epoch.
        public let renderEpoch: String
        /// Stable rendered-content revision for polling.
        public let renderRevision: UInt64
        /// Exact emitted-frame identity for delta continuity.
        public let emissionRevision: UInt64

        public init(
            renderEpoch: String,
            renderRevision: UInt64,
            emissionRevision: UInt64
        ) {
            self.renderEpoch = renderEpoch
            self.renderRevision = renderRevision
            self.emissionRevision = emissionRevision
        }
    }

    /// Depth-independent identity used for both observations and emissions.
    /// Scrollback depth is a request option, not a terminal mutation, so the
    /// history payload is compared by its newest-row overlap instead of its
    /// requested length.
    private struct ObservationContent: Equatable, Sendable {
        let columns: Int
        let rows: Int
        let activeScreen: MobileTerminalRenderGridFrame.Screen
        let anchor: MobileTerminalRenderGridFrame.Anchor
        let rowSignatures: [String]
        let historyRows: UInt64?
        let rowSpaceRevision: UInt64?
        let scrollbackRows: Int
        let scrollbackSignatures: [String]
        let cursor: MobileTerminalRenderGridFrame.Cursor?
        let terminalForeground: String?
        let terminalBackground: String?
        let terminalCursorColor: String?
        let terminalTheme: TerminalTheme?
        let terminalConfigTheme: TerminalTheme?

        init(_ content: MobileTerminalRenderGridContent) {
            columns = content.columns
            rows = content.rows
            activeScreen = content.activeScreen
            anchor = content.anchor
            rowSignatures = content.rowSignatures
            historyRows = content.historyRows
            rowSpaceRevision = content.rowSpaceRevision
            scrollbackRows = max(0, content.scrollbackRows)
            scrollbackSignatures = content.scrollbackSignatures
            cursor = content.cursor
            terminalForeground = content.terminalForeground
            terminalBackground = content.terminalBackground
            terminalCursorColor = content.terminalCursorColor
            terminalTheme = content.terminalTheme
            terminalConfigTheme = content.terminalConfigTheme
        }

        /// Compares history payloads by their newest-row overlap, not by the
        /// request's scrollback depth. A replay asking for 20 rows and a replay
        /// asking for 200 rows therefore identify the same terminal state when
        /// their shared tail is unchanged. Absolute history metadata, when
        /// present, aligns rows across captures; legacy frames align them from
        /// the newest row backwards.
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.columns == rhs.columns
                && lhs.rows == rhs.rows
                && lhs.activeScreen == rhs.activeScreen
                && lhs.anchor == rhs.anchor
                && lhs.rowSignatures == rhs.rowSignatures
                && lhs.historyRows == rhs.historyRows
                && lhs.rowSpaceRevision == rhs.rowSpaceRevision
                && lhs.cursor == rhs.cursor
                && lhs.terminalForeground == rhs.terminalForeground
                && lhs.terminalBackground == rhs.terminalBackground
                && lhs.terminalCursorColor == rhs.terminalCursorColor
                && lhs.terminalTheme == rhs.terminalTheme
                && lhs.terminalConfigTheme == rhs.terminalConfigTheme
                && lhs.historyPayloadMatches(rhs)
        }

        private func historyPayloadMatches(_ other: Self) -> Bool {
            guard scrollbackRows > 0, other.scrollbackRows > 0 else {
                // A zero-depth capture carries no history payload; it cannot
                // contradict a deeper capture when the absolute history
                // identity above is unchanged.
                return true
            }
            let lhsBase = historyBase
            let rhsBase = other.historyBase
            let lower = max(lhsBase, rhsBase)
            let upper = min(
                lhsBase + scrollbackRows - 1,
                rhsBase + other.scrollbackRows - 1
            )
            guard lower <= upper else { return true }
            let lhsRows = rowSignaturesByAbsoluteRow(base: lhsBase)
            let rhsRows = other.rowSignaturesByAbsoluteRow(base: rhsBase)
            for row in lower...upper where lhsRows[row] != rhsRows[row] {
                return false
            }
            return true
        }

        private var historyBase: Int {
            if let historyRows {
                let boundedHistoryRows = min(historyRows, UInt64(Int.max))
                return Int(boundedHistoryRows) - scrollbackRows
            }
            // Negative indexes make the newest row `-1`, which gives captures
            // with different depths a common coordinate system.
            return -scrollbackRows
        }

        private func rowSignaturesByAbsoluteRow(base: Int) -> [Int: String] {
            var rows: [Int: String] = [:]
            for signature in scrollbackSignatures {
                guard let separator = signature.firstIndex(of: ":"),
                      let localRow = Int(signature[..<separator]) else {
                    continue
                }
                let remainder = String(signature[signature.index(after: separator)...])
                let absoluteRow = base + localRow
                if let existing = rows[absoluteRow] {
                    rows[absoluteRow] = existing + "\u{1F}" + remainder
                } else {
                    rows[absoluteRow] = remainder
                }
            }
            return rows
        }
    }

    private let renderEpoch: String
    private var renderRevision: UInt64 = 0
    private var emissionRevision: UInt64 = 0
    private var lastObservationContent: ObservationContent?

    /// Creates a tracker for one terminal-runtime lifetime.
    ///
    /// - Parameter renderEpoch: Stable producer epoch. The default is a new
    ///   UUID, while a surface owner may inject an existing epoch when it
    ///   creates an anchor-specific tracker.
    public init(renderEpoch: String = UUID().uuidString) {
        self.renderEpoch = renderEpoch
    }

    /// The current identity before another frame is emitted.
    public var currentIdentity: Identity {
        Identity(
            renderEpoch: renderEpoch,
            renderRevision: renderRevision,
            emissionRevision: emissionRevision
        )
    }

    /// Records one complete rendered frame and returns its identity.
    ///
    /// The frame must be a full snapshot. Transport metadata such as
    /// ``MobileTerminalRenderGridFrame/stateSeq``, theme metadata revisions,
    /// and non-visual mode flags are deliberately excluded from the content
    /// comparison, so output that does not alter visible pixels remains on the
    /// same polling revision.
    /// Every successful call still receives a distinct emission revision.
    ///
    /// - Parameter fullFrame: Complete frame exported by the producer before
    ///   transport filtering or delta encoding.
    /// - Parameter content: Optional content snapshot computed while choosing
    ///   the emission. Passing it avoids a second span scan; when omitted, the
    ///   tracker computes one for standalone callers.
    /// - Returns: The content and emission revisions for this frame.
    public mutating func record(
        fullFrame: MobileTerminalRenderGridFrame,
        content: MobileTerminalRenderGridContent? = nil
    ) -> Identity {
        let renderedContent = content ?? fullFrame.renderedContent()
        updateObservationRevision(ObservationContent(renderedContent))
        emissionRevision &+= 1
        if emissionRevision == 0 {
            emissionRevision = 1
        }
        return currentIdentity
    }

    /// Observes one complete frame without claiming a new transport emission.
    ///
    /// Request/response projections use this to initialize or advance the
    /// shared content polling token without changing the exact-emission
    /// sequence used by delta consumers.
    ///
    /// - Parameters:
    ///   - fullFrame: Complete frame exported by the producer.
    ///   - content: Optional snapshot already computed by an emission decision.
    /// - Returns: The current content and emission identity.
    public mutating func observe(
        fullFrame: MobileTerminalRenderGridFrame,
        content: MobileTerminalRenderGridContent? = nil
    ) -> Identity {
        let renderedContent = content ?? fullFrame.renderedContent()
        updateObservationRevision(ObservationContent(renderedContent))
        // Observation is deliberately not an emission. Returning the current
        // emission counter here would let a request/response projection reuse
        // an unrelated live-frame identity as a delta baseline.
        return Identity(
            renderEpoch: renderEpoch,
            renderRevision: renderRevision,
            emissionRevision: 0
        )
    }

    private mutating func updateObservationRevision(
        _ content: ObservationContent
    ) {
        guard lastObservationContent != content else { return }
        renderRevision &+= 1
        if renderRevision == 0 {
            renderRevision = 1
        }
        lastObservationContent = content
    }

}
