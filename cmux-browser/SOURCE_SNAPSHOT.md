# cmux Browser source snapshot

This ledger records immutable Git objects and content digests for public
source slices imported from the private Browser candidate. It contains no
private repository URL, filesystem path, builder identity, or release
credential.

## Slice 1: cmux-TUI protocol core

- Import date: 2026-07-22
- Private candidate commit:
  `0821bef9ec386799dc80f7ef67263d31461c2b4a`
- Private candidate tree:
  `8f65f11a28479674dcb1d0a20f849c2f00b6073c`
- Private archive tag:
  `cmux-browser-public-snapshot-20260722-slice1`
- Provenance: Manaflow rights-controlled
- License: GPL-3.0-or-later

| Public path | Source blob | SHA-256 |
| --- | --- | --- |
| `overlay/chrome/browser/cmux_term/cmux_tui_protocol.h` | `96be295235f03caa7db2b59e0ccd0eb69f8ca273` | `ae3177c8791cabaf5d4f6098aa30c69a52a70f019440d75189ee65321ed89fcb` |
| `overlay/chrome/browser/cmux_term/cmux_tui_protocol.cc` | `74a1bf36a1d49c71f64ab9019e806f5fbe6e9a59` | `660c117fb35026167b1f0ae0660ecb711c99a68613bcfa2bdd4c54724e8ab570` |
| `overlay/chrome/browser/cmux_term/cmux_tui_protocol_test.cc` | `8fb0689767dc238683baaad5948a9e8eec97ea54` | `239846863313da157e964e6573226708ee8c55b70350cf55f606d91f635bc5ec` |

The three source files were copied byte-for-byte. The public-only host-test
wrapper and documentation are not private snapshot material.

The private archive retains the annotated tag above. The commit, tree, blob,
and content IDs provide the reproducible identity needed to audit this slice
without exposing private history.
