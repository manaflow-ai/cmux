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

    /// Capture-independent identity used while a surface has only
    /// request/response observations. Scrollback depth is a request option,
    /// not a terminal mutation, so it is intentionally absent here. Once the
    /// first real emission arrives, the full rendered-content identity is used
    /// for producer-side comparisons.
    private struct ObservationContent: Equatable, Sendable {
        let columns: Int
        let rows: Int
        let activeScreen: MobileTerminalRenderGridFrame.Screen
        let anchor: MobileTerminalRenderGridFrame.Anchor
        let rowSignatures: [String]
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
            cursor = content.cursor
            terminalForeground = content.terminalForeground
            terminalBackground = content.terminalBackground
            terminalCursorColor = content.terminalCursorColor
            terminalTheme = content.terminalTheme
            terminalConfigTheme = content.terminalConfigTheme
        }
    }

    private let renderEpoch: String
    private var renderRevision: UInt64 = 0
    private var emissionRevision: UInt64 = 0
    private var lastContent: MobileTerminalRenderGridContent?
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
        if emissionRevision == 0 {
            // A request-only baseline may have been initialized with a
            // different scrollback budget. Reuse its capture-independent
            // identity for the first real emission, then switch to the full
            // producer identity for all subsequent emissions.
            updateObservationRevision(ObservationContent(renderedContent))
        } else {
            updateContentRevision(renderedContent)
        }
        lastContent = renderedContent
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
        // Once a real event has established the producer baseline, a
        // request/response replay must not replace it with a capture carrying
        // a different scrollback budget. Such a replacement would make the
        // next event look like a content change even when only the requested
        // history depth changed. The event producer remains the authority for
        // subsequent revisions; observations still return its current token.
        guard emissionRevision == 0 else {
            return Identity(
                renderEpoch: renderEpoch,
                renderRevision: renderRevision,
                emissionRevision: 0
            )
        }
        let renderedContent = content ?? fullFrame.renderedContent()
        // Before the first emission, compare only the capture-independent
        // identity so repeated polls with different history depths remain
        // stable while visible output/size changes still advance the token.
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

    private mutating func updateContentRevision(
        _ renderedContent: MobileTerminalRenderGridContent
    ) {
        if lastContent != renderedContent {
            renderRevision &+= 1
            if renderRevision == 0 {
                renderRevision = 1
            }
            lastContent = renderedContent
        }
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
