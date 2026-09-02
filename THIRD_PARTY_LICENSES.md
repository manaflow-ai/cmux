# Third-Party Licenses

cmux includes the following third-party software:

---

## Ghostty

- **License:** MIT License
- **Copyright:** Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors
- **Source:** https://github.com/ghostty-org/ghostty

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

---

## Bonsplit

- **License:** MIT License
- **Copyright:** Copyright (c) 2026 Alasdair Monk
- **Source:** https://github.com/almonk/bonsplit

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

---

## cmux-cua engine

- **License:** MIT License
- **Copyright:** Copyright (c) 2025 Cua AI, Inc.
- **Source:** https://github.com/manaflow-ai/cmux-cua

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

---

## herdr agent-detection plugin

cmux includes a userland agent-detection plugin derived from herdr. Its
manifests and adapted detector sources live under
`cmux-tui/bindings/examples/rust-agent-screen-detection/`.

- **Package license:** MIT AND Apache-2.0
- **Herdr-derived material:** Apache License 2.0
- **Source:** https://github.com/herdrdev/herdr
- **Detector source reference:** commit `7b675f42af35508eab66ac42fe1598628597a893`
- **Pi bundled-launcher correction:** commit `b1ff4582e9688f52ffb943cfa8bee4871ae122e4`
- **Manifest snapshot:** commit `2290257acb2085ce6842ba5c7e3ca50c3ba64f02`
- **Included manifest fixes:** Claude MCP elicitation `f807b697353cfa00aa912c7cde4830e863001cf5`, Claude background-shell state `987b070fbfa187e85009b45cd7e208fc6175ff6a`, Codex weak-blocker scope `f457cff4f2648eee85d176f8a41861241d4e8428`, and Copilot background-agent activity `2290257acb2085ce6842ba5c7e3ca50c3ba64f02`
- **License text:** cmux-owned code is covered by
  `cmux-tui/bindings/examples/rust-agent-screen-detection/LICENSE-MIT`; the
  herdr-derived files use
  `cmux-tui/bindings/examples/rust-agent-screen-detection/manifests/LICENSE`
- **Latest agent-surface capability audit:** commit `987b070fbfa187e85009b45cd7e208fc6175ff6a`. The herdr repository tip checked on 2026-09-02 is `5a2dee700eeeea68267a4d16777307632f77172f`; commits after the audit pin change client mouse selection and Windows worktree removal, with no further `src/detect` or manifest changes. The audit includes the exact Pi bundled CLI path correction from `b1ff4582e9688f52ffb943cfa8bee4871ae122e4` and the Claude background-shell state correction from `987b070fbfa187e85009b45cd7e208fc6175ff6a`, both adapted and tested in the userland package. The first-acquisition OSC retention fix from `82e6a80eb3ae39fb3d3ebd4d1fed19389767e605` is adapted in the userland tracker. The foreground group-leader CWD fix from `3a3792622e59c7f2dc20f9c0236167161e4a5035` is already covered by cmux's generic `foreground_cwd` resource. The shell-render refactor in `207be3c771d281baae6e5fa0fb74be9a056e97a2` and independent multi-client tab views in `6c0bb273d5d5405a00985621b17e36f8b4d64609` are application/client architecture and are not copied. The delayed-agent-prompt fix in `8633a398e653eee47b375c963996c78a8a14aa48` changes PTY input sequencing, and `5616196942cbe752cc0659b9bd0fb616b2a6ed5c` hardens malformed Windows process environments in portable-pty. These changes are outside detector behavior and are not copied. SDK endpoint-generation compatibility remains a standalone-release requirement; review the Windows changes before publishing a Windows package.

Nineteen manifests are unchanged from the manifest snapshot. `claude.toml` is
byte-identical to upstream commit `987b070fbfa187e85009b45cd7e208fc6175ff6a`.
`grok.toml` is based on the snapshot file and contains one documented cmux
precedence correction. The manifest engine, process discovery, state detector, and update
logic are adapted for the cmux userland plugin contract. The source paths,
commits, license, and adaptations are recorded in
`cmux-tui/bindings/examples/rust-agent-screen-detection/ATTRIBUTIONS.md`.
The SHA256SUMS file is a checked-in byte-provenance record verified before the
bundled manifests are compiled. It detects accidental drift, but it is not a
cryptographic release signature for remote updates.

---

## Sparkle

- **License:** MIT License
- **Copyright:** Copyright (c) 2006-2013 Andy Matuschak, 2009-2013 Elgato Systems GmbH, 2011-2014 Kornel Lesinski, 2015-2017 Sparkle Project
- **Source:** https://github.com/sparkle-project/Sparkle

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## PostHog iOS

- **License:** MIT License
- **Copyright:** Copyright (c) 2020 PostHog
- **Source:** https://github.com/PostHog/posthog-ios

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

---

## Sentry Cocoa

- **License:** MIT License
- **Copyright:** Copyright (c) 2015 Sentry
- **Source:** https://github.com/getsentry/sentry-cocoa

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

---

## Markdown Viewer Web Assets

cmux bundles these files under `Resources/markdown-viewer/` so the markdown
viewer has no runtime CDN dependency.

### marked

- **Version:** 13.0.3
- **License:** MIT License
- **Copyright:** Copyright (c) 2011-2024, Christopher Jeffrey
- **Source:** https://github.com/markedjs/marked/releases/tag/v13.0.3

### highlight.js

- **Version:** 11.10.0
- **License:** BSD 3-Clause License
- **Copyright:** Copyright (c) 2006-2024 Josh Goebel and other contributors
- **Source:** https://github.com/highlightjs/highlight.js/releases/tag/11.10.0

### github-markdown-css

- **Version:** 5.6.1
- **License:** MIT License
- **Copyright:** Copyright (c) Sindre Sorhus
- **Source:** https://github.com/sindresorhus/github-markdown-css/tree/v5.6.1

### Mermaid

- **Version:** 11.4.1
- **License:** MIT License
- **Copyright:** Copyright (c) 2014-2024 Knut Sveidqvist and Mermaid contributors
- **Source:** https://github.com/mermaid-js/mermaid/releases/tag/mermaid%4011.4.1

### Vega

- **Version:** 5.30.0
- **License:** BSD 3-Clause License
- **Copyright:** Copyright (c) 2015-2024 University of Washington Interactive Data Lab and contributors
- **Source:** https://github.com/vega/vega/releases/tag/v5.30.0

### Vega-Lite

- **Version:** 5.21.0
- **License:** BSD 3-Clause License
- **Copyright:** Copyright (c) 2015-2024 University of Washington Interactive Data Lab and contributors
- **Source:** https://github.com/vega/vega-lite/releases/tag/v5.21.0

### Vega-Embed

- **Version:** 6.26.0
- **License:** BSD 3-Clause License
- **Copyright:** Copyright (c) 2015-2024 University of Washington Interactive Data Lab and contributors
- **Source:** https://github.com/vega/vega-embed/releases/tag/v6.26.0

BSD 3-Clause License:

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.
3. Neither the name of the copyright holder nor the names of its contributors
   may be used to endorse or promote products derived from this software
   without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

---

## Swift Package Dependencies

The following packages are linked into the cmux app binary.

### MarkdownUI (swift-markdown-ui)

- **License:** MIT License
- **Copyright:** Copyright (c) 2020 Guillermo Gonzalez
- **Source:** https://github.com/gonzalezreal/swift-markdown-ui

### NetworkImage

- **License:** MIT License
- **Copyright:** Copyright (c) 2020 Guille Gonzalez
- **Source:** https://github.com/gonzalezreal/NetworkImage

### swift-cmark (cmark / cmark-gfm)

- **License:** BSD 2-Clause License (and MIT-licensed portions; see upstream COPYING)
- **Copyright:** Copyright (c) 2014, John MacFarlane; cmark-gfm portions Copyright (c) 2017, GitHub, Inc.
- **Source:** https://github.com/swiftlang/swift-cmark

### XcodeProj

- **License:** MIT License
- **Copyright:** Copyright (c) from 2018 Pedro Piñera Buendía and contributors
- **Source:** https://github.com/tuist/XcodeProj

### AEXML

- **License:** MIT License
- **Copyright:** Copyright (c) 2014-2024 Marko Tadić
- **Source:** https://github.com/tadija/AEXML

### PathKit

- **License:** BSD 2-Clause License
- **Copyright:** Copyright (c) 2014, Kyle Fuller
- **Source:** https://github.com/kylef/PathKit

### iroh-ffi

- **License:** MIT License or Apache License 2.0 (dual-licensed; cmux elects MIT)
- **Copyright:** Copyright 2025 N0, INC.
- **Source:** https://github.com/manaflow-ai/iroh-ffi (fork of https://github.com/n0-computer/iroh-ffi)

### Swift Crypto and Swift ASN.1

- **License:** Apache License 2.0
- **Copyright:** Copyright (c) Apple Inc. and the SwiftCrypto / SwiftASN1 project authors
- **Source:** https://github.com/apple/swift-crypto, https://github.com/apple/swift-asn1

### Stack Auth Swift SDK

- **License:** MIT License (per Stack Auth's published per-package licensing policy,
  under which client SDKs are MIT-licensed; the vendored prerelease does not yet
  include its own LICENSE file)
- **Copyright:** Copyright (c) Stack Auth (HexClave, Inc.)
- **Source:** https://github.com/stack-auth/stack

---

## Diff Viewer Highlighting Assets

cmux bundles compiled syntax-highlighting code and grammars under
`Resources/markdown-viewer/diff-viewer/` so the diff viewer has no runtime CDN
dependency.

### shiki

- **License:** MIT License
- **Copyright:** Copyright (c) 2021 Pine Wu; Copyright (c) 2023 Anthony Fu and Shiki contributors
- **Source:** https://github.com/shikijs/shiki

### vscode-textmate

- **License:** MIT License
- **Copyright:** Copyright (c) Microsoft Corporation
- **Source:** https://github.com/microsoft/vscode-textmate

### vscode-oniguruma

- **License:** MIT License
- **Copyright:** Copyright (c) Microsoft Corporation
- **Source:** https://github.com/microsoft/vscode-oniguruma

### Oniguruma

- **License:** BSD 2-Clause License
- **Copyright:** Copyright (c) 2002-2019 K.Kosako
- **Source:** https://github.com/kkos/oniguruma (bundled as WebAssembly via vscode-oniguruma)

---

## Shared License Texts

MIT-licensed components above are distributed under the MIT License text
reproduced in the sections earlier in this document. BSD 2-Clause components
are distributed under the following text:

BSD 2-Clause License:

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

Apache-2.0-licensed components are distributed under the Apache License,
Version 2.0. A copy of the license is available at
http://www.apache.org/licenses/LICENSE-2.0 and in each component's source
repository listed above.
