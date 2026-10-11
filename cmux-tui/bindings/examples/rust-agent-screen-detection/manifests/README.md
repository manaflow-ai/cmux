# herdr agent-detection manifests

These TOML files are byte-identical to `src/detect/manifests/` of
https://github.com/ogulcancelik/herdr (Apache-2.0, see `LICENSE`) at commit
`2563803dca97c040beaf3dc3acdcb5a3221b4238` (herdr 0.9.3). No file carries a
local cmux patch. `../HERDR_UPSTREAM.toml` records the pin and the upstream
sha256 of each file; `../HERDR_PATCHES.toml` is where a documented cmux edit
would be listed, and a patched file would be flagged `local_patch = true` with
its reason in the pin. The cmux package adapts the rule semantics in the
separately attributed Rust engine.

Do not fetch herdr's manifest update endpoint, and do not edit these files by
hand. Refresh them from a herdr checkout:

```text
python3 -I scripts/cmux-next/herdr-sync.py sync --herdr <herdr checkout> --rev <commit>
python3 -I scripts/cmux-next/herdr-sync.py check
```

`sync` reads the files with `git show` (it never checks out the herdr tree),
reapplies the documented patches or fails when one no longer applies, and
rewrites `SHA256SUMS` and the pin. A new upstream manifest also needs an entry
in `src/manifest.rs`. Review the upstream engine changes that `drift` lists
and update `../ATTRIBUTIONS.md` in the same change.

SHA256SUMS records the bytes embedded by the plugin. The provenance test checks
this record before the bundled set is compiled, and `herdr-sync.py check` runs
on every push, so an accidental edit cannot silently change a vendored rule.
The record is not a release signature: remote updates still need
authenticated, signed catalog data before they can be treated as trusted.
