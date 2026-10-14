/// Agent delivery policy and evidence live in the app-independent package.
/// Re-exporting the package through the app module keeps existing callers and
/// tests source-compatible while the Darwin inspector remains app-owned.
@_exported import CmuxCore
