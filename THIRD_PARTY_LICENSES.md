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

## Bun Runtime

cmux uses `bun build --compile` to package the computer-use MCP server as a
standalone executable, which embeds the Bun runtime in that executable.

- **License:** MIT License for Bun itself; linked runtime components carry
  their respective licenses, including LGPL-2.0 for JavaScriptCore/WebKit.
- **Source:** https://github.com/oven-sh/bun
- **License notices:** https://github.com/oven-sh/bun/blob/main/LICENSE.md

The upstream Bun license file identifies the linked runtime components and
their corresponding license terms.

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
