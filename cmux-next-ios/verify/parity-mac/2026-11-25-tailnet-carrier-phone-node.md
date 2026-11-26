# Tailscale carrier from the phone (an in-app userspace tailnet node; direct over the tailnet, else the relay)

- Section: Transport
- Mac sends: nothing new; the Mac's `transport.tailnetCarrier` listener (acpmux `tailnet_carrier`) admits the same owner's untagged node
- Phone: `transport.tailnetCarrier` (off, direct-only, on; default off); the node is `cmux-mobile-tailnet` (Rust): libtailscale tsnet in the app's own process, no NetworkExtension or VPN entitlement, only cmux's own streams dial through it
- State: partial
- Notes: decision (a) an in-app userspace node, with (b) the existing relay as the fallback. Rust route rules, Keychain item rules, key advice, Forget and the fallback are done and tested; the Linux build of the same path passed on a throwaway headscale (join 2099 ms, direct path after 359 ms, tailnet RTT p50 0.31 ms / p95 0.53 ms, dial-failed and carrier-off fall back to the relay with a reported route change, Forget removes the node; `cmux-next-ios/rust/crates/cmux-mobile-tailnet/testing/phone-node-e2e.sh`). Still missing for the phone: the GOOS=ios libtailscale build on a Mac, its FFI in cmux-mobile-link-ffi, the key sheet and Forget UI over `TailnetKeyStore`, and an on-device number
