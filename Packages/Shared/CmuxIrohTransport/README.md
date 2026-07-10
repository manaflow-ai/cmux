# CmuxIrohTransport

`CmuxIrohTransport` owns cmux's versioned Iroh application protocol. The package
is shared by macOS and iOS and keeps generated Iroh FFI handles behind injected
transport seams.

The first bytes on every QUIC stream are a bounded binary header identifying
the lane. A connection begins with an authenticated control stream. Subsequent
server-event, terminal, and artifact streams reuse the authenticated QUIC
connection and retain independent cancellation and backpressure.

Run the package behavior tests without launching either app:

```sh
swift test --package-path Packages/Shared/CmuxIrohTransport
```
