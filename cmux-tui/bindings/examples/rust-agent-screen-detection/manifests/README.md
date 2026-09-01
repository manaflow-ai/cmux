# herdr agent-detection manifests

Twenty of these TOML files are vendored unchanged from
https://github.com/herdrdev/herdr (Apache-2.0, see LICENSE), at commit
`7b675f42af35508eab66ac42fe1598628597a893`, path `src/detect/manifests/`.
`grok.toml` is based on that file and carries one cmux correction: idle OSC
progress wins over a generic custom title, while an explicit spinner still
wins over retained idle metadata. The local patch version is
`2026.07.16.2.1`. The cmux package adapts their semantics in the separately
attributed Rust engine. Do not fetch herdr's manifest update endpoint. Refresh
the unchanged files by re-vendoring and reapply the Grok correction when
bumping this pin.
