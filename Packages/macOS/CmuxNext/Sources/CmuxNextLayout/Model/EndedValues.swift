/// The values a key press or a drag's release ends with (a split ratio, a column width, a key trade's two widths, an
/// Option or Command drag's widths and ratios), sent as one change, all or nothing (FRAME OWNER REFACTOR KEYS, reviews of
/// #34123):
/// - Checked before anything shows: every value has its target, and the app can send it now (`LayoutModel.sendsNow`: a
///   pane the daemon has not made yet refuses every command). Else nothing shows and nothing goes.
/// - Shown in one turn, and sent as one intent with one reply: one value as its own command, more than one as
///   `LayoutIntent.setLayoutSizes`, which a daemon with `layout-sizes-batch-v1` applies as one commit, every value or
///   none (one undo step). The transaction settles at that reply (`TransactionReplies`).
/// - A change the app refuses while it goes out (`LayoutModel.rejectTransaction` notes it) shows the daemon's values
///   again. A change the app answers and applies in this turn is a sent one.
/// A daemon without the capability still gets one command per value: there a value the daemon refuses after another
/// was applied leaves that one applied (`LayoutSizeCommands`).
@MainActor
public struct EndedValues {
    public let values: [DividerDragValue]
    public let transaction: LayoutTransactionID

    public init(_ values: [DividerDragValue], transaction: LayoutTransactionID = .make()) {
        self.values = values
        self.transaction = transaction
    }

    /// Whether every value has its target in `model` and can go to the daemon now.
    public func canSend(in model: LayoutModel) -> Bool {
        values.allSatisfy { value in target(of: value, in: model).map { model.sendsNow?(intent($0)) ?? true } ?? false }
    }

    /// Shows the values in `model` and sends them. False when they could not all go: nothing of them shows.
    @discardableResult
    public func send(in model: LayoutModel) -> Bool {
        guard !values.isEmpty else { return true }
        guard canSend(in: model) else {
            // A drag's live values of this transaction go back too.
            model.rejectTransaction(transaction)
            return false
        }
        for value in values {
            switch value {
            case let .ratio(split, ratio): model.setSplitRatio(split, ratio: ratio, transaction: transaction, phase: .changed)
            case let .width(column, width): model.setColumnWidth(column, width: width, transaction: transaction, phase: .changed)
            }
        }
        let ended = values.compactMap { end($0, in: model) }
        // One intent, so one reply settles the transaction.
        if !ended.isEmpty { model.expectReply(transaction) }
        // A refusal is noted where it happens (`LayoutModel.rejectTransaction`): a handler that answers and applies the
        // daemon's snapshot in this turn removes the overrides too, because the change succeeded.
        model.replies.beginSending(transaction)
        if let first = ended.first {
            model.emit(ended.count > 1 ? .setLayoutSizes(ended, transaction: transaction) : intent(first))
        }
        return !model.replies.endSending()
    }

    /// `value` with its target in `model` (a column by one of its panes); nil when the target is gone.
    private func target(of value: DividerDragValue, in model: LayoutModel) -> LayoutIntent.SizeValue? {
        switch value {
        case let .ratio(split, ratio):
            guard model.screens.contains(where: { $0.layout.ratio(of: split) != nil }) else { return nil }
            return .ratio(split, ratio)
        case let .width(column, width):
            guard let anyPane = model.screens.lazy.compactMap({ $0.layout.columns.first { $0.id == column }?.root.panes.first }).first else {
                return nil
            }
            return .width(column, anyPane: anyPane, width)
        }
    }

    /// The command that sends `value` alone.
    private func intent(_ value: LayoutIntent.SizeValue) -> LayoutIntent {
        switch value {
        case let .ratio(split, ratio):
            .setSplitRatio(split, ratio: ratio, transaction: transaction, phase: .ended)
        case let .width(column, anyPane, width):
            .setColumnWidth(column, anyPane: anyPane, width: width, transaction: transaction, phase: .ended)
        }
    }

    /// Marks `value`'s shown override ended (the daemon's next snapshot does not replace it until its reply) and returns
    /// it with the clamped value the model shows.
    private func end(_ value: DividerDragValue, in model: LayoutModel) -> LayoutIntent.SizeValue? {
        switch value {
        case let .ratio(split, _):
            guard let shown = model.splitOverrides[split], shown.transaction == transaction else { return nil }
            model.splitOverrides[split]?.ended = true
            return target(of: .ratio(split, shown.value), in: model)
        case let .width(column, _):
            guard let shown = model.widthOverrides[column], shown.transaction == transaction else { return nil }
            model.widthOverrides[column]?.ended = true
            return target(of: .width(column, shown.value), in: model)
        }
    }
}
