# herdr agent-detection manifests

Twenty of these TOML files are unchanged from
https://github.com/herdrdev/herdr (Apache-2.0, see LICENSE), at manifest
snapshot commit `2290257acb2085ce6842ba5c7e3ca50c3ba64f02`, path
`src/detect/manifests/`. `grok.toml` is based on the snapshot file and carries
one cmux correction: idle OSC progress wins over a generic custom title, while
an explicit spinner still wins over retained idle metadata.
The local patch version is `2026.07.16.2.1`. The cmux package adapts their
semantics in the separately attributed Rust engine. Do not fetch herdr's
manifest update endpoint. Refresh files from the exact snapshot commit and
reapply the Grok correction when changing this pin.

SHA256SUMS records the bytes embedded by the plugin. The provenance test
checks this record before the bundled set is compiled, so an accidental edit
cannot silently change a vendored rule. The record is not a release signature:
remote updates still need authenticated, signed catalog data before they can be
treated as trusted.

The capability audit was rerun against herdr master
`cc88b3b8e5bb9f7d9f23ed6ae85a52fd7b5b9ed6`. That tip changes stable client
endpoint compatibility outside `src/detect/manifests/`; it changes no bundled
detector manifest. The package does not claim parity with that transport work.
