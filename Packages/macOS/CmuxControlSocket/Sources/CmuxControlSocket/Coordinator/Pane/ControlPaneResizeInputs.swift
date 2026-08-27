public import Foundation

/// The pre-parsed inputs `pane.resize` carries, as ``ControlCommandCoordinator``
/// hands them to ``ControlPaneContext``.
///
/// The coordinator parses each value (mirroring the legacy `v2*` parsing) and
/// performs the present-but-invalid validation that returns `invalid_params`;
/// the seam runs the split-tree candidate collection and the divider mutation.
public struct ControlPaneResizeInputs: Sendable, Equatable {
    /// The explicit `pane_id` target, if any; the seam falls back to the focused
    /// pane when absent.
    public let paneID: UUID?
    /// The validated operation and its coordinate system.
    public let intent: ControlPaneResizeIntent

    /// Legacy projection used only by the unchanged local Bonsplit mutation path.
    public var absoluteAxis: String? {
        switch intent {
        case .outerAbsolute(let axis, _),
             .tmuxAbsoluteCells(let axis, _, _),
             .tmuxAbsolutePercentage(let axis, _, _): return axis
        case .borderRelative, .tmuxRelative: return nil
        }
    }

    /// Legacy outer-point projection used only by the local Bonsplit path.
    public var targetPixels: Double? {
        switch intent {
        case .outerAbsolute(_, let points): return points
        case .tmuxAbsoluteCells(_, _, let points),
             .tmuxAbsolutePercentage(_, _, let points): return points
        case .borderRelative, .tmuxRelative: return nil
        }
    }

    /// Legacy direction projection used only by the local Bonsplit path.
    public var direction: String? {
        switch intent {
        case .borderRelative(let direction, _), .tmuxRelative(let direction, _, _): return direction
        case .outerAbsolute, .tmuxAbsoluteCells, .tmuxAbsolutePercentage: return nil
        }
    }

    /// Legacy point delta used only by the local Bonsplit path, or `nil` when
    /// an exact tmux request had no trustworthy local-metrics projection.
    public var amount: Int? {
        switch intent {
        case .borderRelative(_, let points): return points
        case .tmuxRelative(_, _, let points): return points
        case .outerAbsolute, .tmuxAbsoluteCells, .tmuxAbsolutePercentage: return nil
        }
    }

    /// Creates the pane-resize inputs.
    ///
    /// - Parameters:
    ///   - paneID: The explicit `pane_id` target, if any.
    ///   - intent: The validated resize operation and coordinate system.
    public init(
        paneID: UUID?,
        intent: ControlPaneResizeIntent
    ) {
        self.paneID = paneID
        self.intent = intent
    }
}
