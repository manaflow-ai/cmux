public import CmuxNextDesign
public import CoreGraphics
import CmuxNextLayout

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
    /// Rust's `tab_drag_rule_resolve`; no preview and a cancel when the
    /// reducer does not answer.
    public static func resolve(_ proposal: TabDropProposal?, insideWindow: Bool, screenPoint: CGPoint,
                               context: TabDragContext) -> TabDropResolution {
        let request = Wire.ResolveRequest(kind: proposal.map { Wire.Kind($0.kind) },
                                          refusedReason: proposal?.refusedReason,
                                          insideWindow: insideWindow,
                                          point: Wire.Point(screenPoint),
                                          context: Wire.Context(context))
        guard let reply = LayoutReducerJSON().call("tab_drag_rule_resolve", request, as: Wire.ResolveReply.self),
              let outcome = reply.outcome.tabDragOutcome
        else { return TabDropResolution(preview: .none, outcome: .cancel) }
        let preview: TabDropPreview? = switch reply.preview {
        case "target": proposal.map(TabDropPreview.target)
        case "stay": proposal.map(TabDropPreview.stay)
        case "refused": proposal.flatMap { proposal in reply.refusal?.refusal.map { .refused(proposal, $0) } }
        case "new_window": .newWindow(screenPoint: screenPoint)
        case "none": TabDropPreview.none
        default: nil
        }
        guard let preview else { return TabDropResolution(preview: .none, outcome: .cancel) }
        return TabDropResolution(preview: preview, outcome: outcome)
    }
}
