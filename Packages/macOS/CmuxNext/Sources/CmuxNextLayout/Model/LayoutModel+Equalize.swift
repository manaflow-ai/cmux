import Foundation
public import CoreGraphics

/// Equalize Splits (Ctrl-Cmd-=, menu, palette, CLI `pane equalize-splits`): one shared path for every entrypoint.
extension LayoutModel {
    /// What ``equalize(screen:viewportWidth:)`` did.
    public enum EqualizeResult: Equatable, Sendable {
        /// The screen has neither a split nor two columns side by side: nothing to equalize.
        case nothingToEqualize
        /// The changed ratios and widths went out as one change (none when all were equal already).
        case equalized
        /// The app could not send them now (a pane the daemon has not made yet): nothing changed.
        case refused
    }

    /// Gives every split on `screen` even ratios and, on a columns screen, every column the window shows side by side
    /// the same width, a docked side dock (Home's Chief chat) included (``ColumnEqualizer``). The change is one
    /// transaction (one undo step) and springs unless motion is off (`explicitReflowUntil`).
    /// - Parameters:
    ///   - id: The screen to equalize.
    ///   - viewportWidth: The screen's width in points; nil keeps every dock's width (only strip columns equalize).
    /// - Returns: What happened.
    @discardableResult
    public func equalize(screen id: ScreenID, viewportWidth: CGFloat?) -> EqualizeResult {
        guard let screen = screens.first(where: { $0.id == id }) else { return .nothingToEqualize }
        let style = style
        var widths: [String: Double] = [:]
        if case .columns(let columns) = screen.layout {
            for column in columns { widths[column.id.rawValue] = Double(column.minimumSize(style: style).width) }
        }
        let request = EqualizeRequest(layout: screen.layout, zoomed: screen.zoomed, visiblePanes: visiblePanes,
                                      viewportWidth: viewportWidth.map(Double.init), gap: Double(style.stripGap),
                                      minimumWidths: widths)
        guard let reply: EqualizeReply = LayoutRules.call("layout_model_equalize", request),
              reply.outcome == "equalized" else { return .nothingToEqualize }
        let values: [DividerDragValue] = reply.values.compactMap { value in
            if let split = value.split, let ratio = value.ratio { return .ratio(split, ratio) }
            if let column = value.column, let width = value.width { return .width(column, width) }
            return nil
        }
        guard !values.isEmpty else { return .equalized }
        let change = EndedValues(values)
        guard change.canSend(in: self) else { return .refused }
        explicitReflowUntil = ProcessInfo.processInfo.systemUptime + Self.explicitReflowWindow
        return change.send(in: self) ? .equalized : .refused
    }

    /// Equalizes `split` so every cell in its same-axis chain gets equal size. An explicit
    /// equalize springs (`explicitReflowUntil`); the sizing that follows a split or a close moves
    /// with that gesture instead.
    public func equalizeSplit(_ split: SplitID) {
        guard let tree = screens.lazy.compactMap({ $0.layout.tree(containing: split) }).first,
              let ratio = tree.equalizedRatio(for: split) else { return }
        explicitReflowUntil = ProcessInfo.processInfo.systemUptime + Self.explicitReflowWindow
        setSplitRatio(split, ratio: ratio, transaction: .make(), phase: .ended)
    }
}

/// `layout_model_equalize` of cmux-layout-reducer (`schemas/layout-model/vectors.json`): even ratios for every split
/// and, on an unzoomed columns screen, the same width for every column the window shows side by side.
private nonisolated struct EqualizeRequest: Encodable {
    var layout: ScreenLayout
    var zoomed: Bool
    var visiblePanes: Set<PaneID>
    var viewportWidth: Double?
    var gap: Double
    var minimumWidths: [String: Double]
}

private nonisolated struct EqualizeReply: Decodable {
    struct Value: Decodable {
        var split: SplitID?
        var ratio: Double?
        var column: ColumnID?
        var width: Double?
    }

    var outcome: String
    var values: [Value]
}
