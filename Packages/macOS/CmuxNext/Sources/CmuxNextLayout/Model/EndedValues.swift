/// The values a key press or a drag's release ends with (a split ratio, a column width, a key trade's two widths, an
/// Option or Command drag's widths and ratios), sent as one change, all or nothing (FRAME OWNER REFACTOR KEYS, reviews of
/// #34123):
/// - Checked before anything shows: every value has its target, and the app can send it now (`LayoutModel.sendsNow`: a
///   pane the daemon has not made yet refuses every command). Else nothing shows and nothing goes.
/// - Shown in one turn, and counted before the first goes out, so the transaction settles at the reply to its last value
///   (`TransactionReplies`), whenever the replies come.
/// - Sent one command per value under one transaction (one undo step). A value the app refuses while they go out ends
///   the change (`LayoutModel.rejectTransaction` notes it): nothing after it goes, and every value of the transaction
///   shows the daemon's again. A change the app answers and applies in this turn is a sent one.
/// Two commands are still two daemon commits: a value the daemon refuses after the other was applied leaves that one
/// applied (atomic multi-value commits wait for layout op batches, resize-modifiers.md).
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
        values.allSatisfy { value in intent(for: value, in: model).map { model.sendsNow?($0) ?? true } ?? false }
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
        let intents = values.compactMap { end($0, in: model) }
        for _ in intents { model.expectReply(transaction) }
        // A refusal is noted where it happens (`LayoutModel.rejectTransaction`): a handler that answers and applies the
        // daemon's snapshot in this turn removes the overrides too, because the change succeeded.
        model.replies.beginSending(transaction)
        for intent in intents {
            model.emit(intent)
            if model.replies.refusedInnermost { break }
        }
        return !model.replies.endSending()
    }

    /// The command `value` would send, with the clamped value the model shows once it is set; nil when its target is gone.
    private func intent(for value: DividerDragValue, in model: LayoutModel) -> LayoutIntent? {
        switch value {
        case let .ratio(split, ratio):
            guard model.screens.contains(where: { $0.layout.ratio(of: split) != nil }) else { return nil }
            return .setSplitRatio(split, ratio: ratio, transaction: transaction, phase: .ended)
        case let .width(column, width):
            guard let anyPane = model.screens.lazy.compactMap({ $0.layout.columns.first { $0.id == column }?.root.panes.first }).first else {
                return nil
            }
            return .setColumnWidth(column, anyPane: anyPane, width: width, transaction: transaction, phase: .ended)
        }
    }

    /// Marks `value`'s shown override ended (the daemon's next snapshot does not replace it until its reply) and returns
    /// the command that sends it.
    private func end(_ value: DividerDragValue, in model: LayoutModel) -> LayoutIntent? {
        switch value {
        case let .ratio(split, _):
            guard let shown = model.splitOverrides[split], shown.transaction == transaction else { return nil }
            model.splitOverrides[split]?.ended = true
            return intent(for: .ratio(split, shown.value), in: model)
        case let .width(column, _):
            guard let shown = model.widthOverrides[column], shown.transaction == transaction else { return nil }
            model.widthOverrides[column]?.ended = true
            return intent(for: .width(column, shown.value), in: model)
        }
    }
}
