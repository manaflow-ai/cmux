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

    private let renderEpoch: String
    private var renderRevision: UInt64 = 0
    private var emissionRevision: UInt64 = 0
    private var lastContent: MobileTerminalRenderGridContent?

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
        _ = observe(fullFrame: fullFrame, content: content)
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
        if lastContent != renderedContent {
            renderRevision &+= 1
            if renderRevision == 0 {
                renderRevision = 1
            }
            lastContent = renderedContent
        }
        return currentIdentity
    }

}
