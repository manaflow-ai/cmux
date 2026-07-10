# CmuxIrohTransport

`CmuxIrohTransport` owns cmux's versioned Iroh application protocol. The package
is shared by macOS and iOS and keeps generated Iroh FFI handles behind injected
transport seams.

The first bytes on every QUIC stream are a bounded binary header identifying
the lane. A connection begins with an authenticated control stream. Subsequent
server-event, terminal, and artifact streams reuse the authenticated QUIC
connection and retain independent cancellation and backpressure.

Mac admission verifies the signed grant and live QUIC EndpointID before broker
traffic. Authenticated discovery refreshes are coalesced and reused for at most
30 seconds. Confirmed revocation closes only the affected connection, while an
exact connectivity failure preserves a locally valid grant until its signed
expiry. A continuously disconnected revoke can therefore remain usable for no
longer than the grant's seven-day cryptographic lifetime.

Run the package behavior tests without launching either app:

```sh
swift test --package-path Packages/Shared/CmuxIrohTransport
```
