# CmuxIrohTransport

`CmuxIrohTransport` owns cmux's versioned Iroh application protocol. The package
is shared by macOS and iOS and keeps generated Iroh FFI handles behind injected
transport seams.

The first bytes on every QUIC stream are a bounded binary header identifying
the lane. A connection begins with an authenticated control stream. Subsequent
server-event, terminal, and artifact streams reuse the authenticated QUIC
connection and retain independent cancellation and backpressure.

Mac admission verifies signed authority and the live QUIC EndpointID before
broker traffic. First-time offline pairing also verifies and consumes its
one-use proof before discovery. Authenticated refreshes are coalesced and reused
for at most 30 seconds. Confirmed revocation closes only the affected
connection, while exact connectivity failure preserves local authority until
its signed expiry. Cached grants therefore retain a maximum seven-day
disconnected revoke window; first-pair sessions use the earlier of their two
one-day attestation expiries.

Run the package behavior tests without launching either app:

```sh
swift test --package-path Packages/Shared/CmuxIrohTransport
```

An admitted Mac connection gives one supervisor ownership of its control and
application-lane tasks. Injecting those operations keeps the lifetime policy
testable without an endpoint or app process:

```swift
let supervisor = CmxIrohAdmittedConnectionSupervisor(
    runControl: { await serveControl() },
    runApplicationLanes: { await serveApplicationLanes() },
    closeConnection: { await connection.close() },
    stopApplicationLanes: { await lanes.stop() }
)
await supervisor.run()
```
