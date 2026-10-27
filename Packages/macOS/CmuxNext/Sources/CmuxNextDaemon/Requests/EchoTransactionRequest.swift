/// A command whose events echo the client `transaction` it sends (tab moves and closes, tab
/// groups, layout commands, conversation ops). `DaemonConnection.request` records that
/// transaction in the running ``DaemonCommandScope``'s cause before the command goes out, so its
/// echo applies in that cause (``MutationCauseLedger``).
public protocol EchoTransactionRequest: DaemonRequest {
    /// The `transaction` the command's events echo, or nil when it sends none.
    var echoTransaction: ClientTransactionID? { get }
}

extension DaemonCommandScope {
    /// Records the transaction `request` sends, when it sends one, in the ``current`` scope's
    /// cause on `ledger` (the sending connection's).
    static func recordEchoTransaction(of request: some DaemonRequest, in ledger: MutationCauseLedger) {
        guard let scope = current, scope.cause != nil, let echoing = request as? any EchoTransactionRequest,
              let transaction = echoing.echoTransaction else { return }
        scope.recordTransaction(transaction, in: ledger)
    }
}

/// The layout commands send a numeric transaction; the daemon echoes it as a decimal string.
private func decimal(_ transaction: UInt64?) -> ClientTransactionID? {
    transaction.map { ClientTransactionID(rawValue: String($0)) }
}

extension SetSplitRatioRequest: EchoTransactionRequest {
    public var echoTransaction: ClientTransactionID? { decimal(transaction) }
}

extension SetColumnWidthRequest: EchoTransactionRequest {
    public var echoTransaction: ClientTransactionID? { decimal(transaction) }
}

extension SetRowHeightsRequest: EchoTransactionRequest {
    public var echoTransaction: ClientTransactionID? { decimal(transaction) }
}

extension SetColumnDockRequest: EchoTransactionRequest {
    public var echoTransaction: ClientTransactionID? { decimal(transaction) }
}

extension CloseTabsRequest: EchoTransactionRequest {
    public var echoTransaction: ClientTransactionID? { transaction }
}

extension MoveTabRequest: EchoTransactionRequest {
    public var echoTransaction: ClientTransactionID? { transaction }
}

extension MoveTabToWorkspaceRequest: EchoTransactionRequest {
    public var echoTransaction: ClientTransactionID? { transaction }
}

extension MoveTabToNewWorkspaceRequest: EchoTransactionRequest {
    public var echoTransaction: ClientTransactionID? { transaction }
}

extension MoveTabToSplitRequest: EchoTransactionRequest {
    public var echoTransaction: ClientTransactionID? { transaction }
}

extension MoveTabToSplitKeepingFocusRequest: EchoTransactionRequest {
    public var echoTransaction: ClientTransactionID? { transaction }
}

extension MoveTabToColumnRequest: EchoTransactionRequest {
    public var echoTransaction: ClientTransactionID? { transaction }
}

extension MoveTabToSplitRespawnRequest: EchoTransactionRequest {
    public var echoTransaction: ClientTransactionID? { transaction }
}

extension CreateTabGroupRequest: EchoTransactionRequest {
    public var echoTransaction: ClientTransactionID? { transaction }
}

extension AddTabsToGroupRequest: EchoTransactionRequest {
    public var echoTransaction: ClientTransactionID? { transaction }
}

extension RemoveTabsFromGroupRequest: EchoTransactionRequest {
    public var echoTransaction: ClientTransactionID? { transaction }
}

extension MoveTabGroupRequest: EchoTransactionRequest {
    public var echoTransaction: ClientTransactionID? { transaction }
}

extension MoveTabGroupToSplitRequest: EchoTransactionRequest {
    public var echoTransaction: ClientTransactionID? { transaction }
}

extension MoveTabGroupToColumnRequest: EchoTransactionRequest {
    public var echoTransaction: ClientTransactionID? { transaction }
}

extension MoveTabGroupToNewWorkspaceRequest: EchoTransactionRequest {
    public var echoTransaction: ClientTransactionID? { transaction }
}

extension ReopenSavedTabGroupRequest: EchoTransactionRequest {
    public var echoTransaction: ClientTransactionID? { transaction }
}

extension NewConversationTabRequest: EchoTransactionRequest {
    public var echoTransaction: ClientTransactionID? { transaction }
}

extension ConversationOpRequest: EchoTransactionRequest {
    public var echoTransaction: ClientTransactionID? { transaction }
}
