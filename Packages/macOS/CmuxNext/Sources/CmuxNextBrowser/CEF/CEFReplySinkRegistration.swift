import CmuxNextCompat

/// A reply table's entry in ``tables`` for as long as the table holds it (``CEFHostReplies/replySinkToken()``):
/// the token is the context `cmux_remote_shim_set_reply` gets, and the entry goes with the table, so a REPLY frame
/// that comes after the table is gone finds nothing instead of a freed table.
nonisolated final class CEFReplySinkRegistration: Sendable {
    /// The live reply tables by token. The C reply callback gets nothing but its context, so it reaches this
    /// table by name, as FolderWatchStream's callback reaches its own.
    static let tables = CallbackRegistry<CEFHostReplies>(capacity: 64)
    let token: CallbackToken

    init(_ replies: CEFHostReplies) throws(CallbackRegistryError) {
        token = try Self.tables.register(replies)
    }

    deinit {
        Self.tables.unregister(token)
    }
}
