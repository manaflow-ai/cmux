import Foundation

/// The clicks one MCP Servers row can make, as closures over the model, so a row holds only
/// values (the list's snapshot rule: no row keeps a reference to the model).
struct McpServerRowActions {
    let setPolicy: @MainActor (McpToolPolicy, String) -> Void
    let remove: @MainActor () -> Void
    let signIn: @MainActor () -> Void
    /// Sends the key; the row clears its field right after.
    let saveKey: @MainActor (String) -> Void
    /// Approves the held tools.
    let approveTools: @MainActor () -> Void
}
