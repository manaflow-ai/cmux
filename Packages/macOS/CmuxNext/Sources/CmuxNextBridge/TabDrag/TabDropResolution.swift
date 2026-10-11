public import CmuxNextDesign
public import CoreGraphics

/// What the drag shows at the pointer now.
public nonisolated enum TabDropPreview: Hashable, Sendable {
    /// The outline sits on `proposal.highlightFrame`; the drop runs it.
    case target(TabDropProposal)
    /// The outline sits on the tabs' own place; the drop changes nothing.
    case stay(TabDropProposal)
    /// Nothing highlights (Lawrence 2026-10-05: a refused zone just does
    /// not light up); the drop springs back.
    case refused(TabDropProposal, TabDropRefusal)
    /// Outside every app window: a new window opens under the pointer.
    case newWindow(screenPoint: CGPoint)
    /// Inside a window where no surface answered. The resolvers cover every
    /// point, so this is a defect; the drop springs back.
    case none
}

extension TabDropPreview {
    /// Whether the target under the pointer lights up: every preview but a
    /// refused zone.
    public var highlights: Bool {
        if case .refused = self { return false }
        return true
    }
}

/// One resolved pointer position: the preview and the outcome it commits.
public nonisolated struct TabDropResolution: Hashable, Sendable {
    public var preview: TabDropPreview
    public var outcome: TabDragOutcome

    public init(preview: TabDropPreview, outcome: TabDragOutcome) {
        self.preview = preview
        self.outcome = outcome
    }

    /// The refusal the drop reports, if any.
    public var refusal: TabDropRefusal? {
        if case .refused(_, let refusal) = preview { return refusal }
        return nil
    }
}

nonisolated extension TabDragResolver {
    /// The preview and the outcome for the first surface that answered
    /// (`proposal`, nil when none did). The outcome is the preview's: an
    /// accepted target commits its outcome; a stay, a refusal or no answer
    /// commits nothing. `insideWindow` is false outside every app window.
    public static func resolve(_ proposal: TabDropProposal?, insideWindow: Bool, screenPoint: CGPoint,
                               context: TabDragContext) -> TabDropResolution {
        guard insideWindow else {
            return TabDropResolution(preview: .newWindow(screenPoint: screenPoint),
                                     outcome: outcome(for: nil, insideWindow: false, screenPoint: screenPoint, context: context))
        }
        guard let proposal else { return TabDropResolution(preview: .none, outcome: .cancel) }
        if let reason = proposal.refusedReason {
            return TabDropResolution(preview: .refused(proposal, .surface(reason)), outcome: .cancel)
        }
        switch verdict(proposal.kind, context: context) {
        case .accept:
            return TabDropResolution(preview: .target(proposal),
                                     outcome: outcome(for: proposal, insideWindow: true, screenPoint: screenPoint, context: context))
        case .stay:
            return TabDropResolution(preview: .stay(proposal), outcome: .cancel)
        case .refuse(let refusal):
            return TabDropResolution(preview: .refused(proposal, refusal), outcome: .cancel)
        }
    }
}
