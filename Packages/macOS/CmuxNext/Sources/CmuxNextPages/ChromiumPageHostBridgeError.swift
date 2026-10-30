/// Why ``ChromiumPageHostBridge/setUp(documentScripts:)`` failed before any DevTools call.
public nonisolated enum ChromiumPageHostBridgeError: Error, Equatable {
    /// The page closed first.
    case pageGone
}
