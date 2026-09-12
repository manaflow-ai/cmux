# CmuxHive

The macOS pairing boundary for Computers settings and the native Devices sidebar.
It reuses the existing macOS-capable mobile RPC, transport, and paired-Mac store
packages without depending on the iOS shell or introducing another terminal renderer.

## Ownership and authorization

Create one `HivePairingController` per authenticated account generation and exact
team scope. Pass account-bound token closures through `HiveSyncRuntime`, then call
`stop()` before replacing that scope. The app adapter publishes value snapshots to
Settings and supplies the native device-link owner with persisted endpoint grants.

Only a user-entered numeric Tailscale IP and port, or a pasted compatible pairing
URL, permits the initial dial. A successful authenticated host-status exchange
establishes the device and build-tag identity before a local grant is stored.
Registry and presence metadata never create grants. Unpairing removes the exact
account/team/device/tag record and revokes its live projection; it does not delete
the other Mac's workspaces or unregister the Mac from the account.

## Tests

Run on a leased remote Mac, not the shared local development Mac:

```sh
swift test --package-path Packages/macOS/CmuxHive
```

`HivePairingSecurityTests` injects a framed RPC peer and a temporary SQLite store
through the controller's internal initializer. It exercises pairing proof, exact
endpoint grants, account preflight, scoped deletion, reload, and cancellation
without launching the application or reading the user's preferences or credentials.
