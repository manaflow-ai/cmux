/// A bounded registry resource named by a `limit-exceeded` conflict.
public enum BackendProjectionNavigationLimit: String, Codable, Equatable, Sendable {
    /// Logical-window records retained for one stable client.
    case recordsPerClient = "records-per-client"

    /// Logical-window records retained across all clients.
    case recordsGlobal = "records-global"

    /// Logical-window records changed by one mutation batch.
    case recordsPerBatch = "records-per-batch"

    /// Assigned workspaces retained by one logical window.
    case workspacesPerRecord = "workspaces-per-record"

    /// Assigned workspace bindings retained across all logical windows.
    case workspaceBindingsGlobal = "workspace-bindings-global"

    /// Screen preferences retained by one logical window.
    case screenPreferencesPerRecord = "screen-preferences-per-record"

    /// Screen preferences retained across all logical windows.
    case screenPreferencesGlobal = "screen-preferences-global"

    /// Pane preferences retained by one logical window.
    case panePreferencesPerRecord = "pane-preferences-per-record"

    /// Pane preferences retained across all logical windows.
    case panePreferencesGlobal = "pane-preferences-global"

    /// Operations accepted for one logical window in a batch.
    case operationsPerRecord = "operations-per-record"

    /// Operations accepted across one mutation batch.
    case operationsPerBatch = "operations-per-batch"

    /// Schema floors retained for one client.
    case schemaFloorsPerClient = "schema-floors-per-client"

    /// Schema floors retained across all clients.
    case schemaFloorsGlobal = "schema-floors-global"

    /// Serialized bytes in one response.
    case responseBytes = "response-bytes"

    /// Idempotent mutation receipts retained for one client.
    case replayReceiptsPerClient = "replay-receipts-per-client"

    /// Idempotent mutation receipts retained across all clients.
    case replayReceiptsGlobal = "replay-receipts-global"

    /// Serialized replay-receipt bytes retained for one client.
    case replayReceiptBytesPerClient = "replay-receipt-bytes-per-client"

    /// Serialized replay-receipt bytes retained across all clients.
    case replayReceiptBytesGlobal = "replay-receipt-bytes-global"
}
