# Bundled fonts

Inter is the UI font of cmux NEXT, native and web (Leo 2026-10-21, ask-52da478628). The files are
unmodified copies from the official Inter 4.1 release,
https://github.com/rsms/inter/releases/download/v4.1/Inter-4.1.zip
(sha256 `9883fdd4a49d4fb66bd8177ba6625ef9a64aa45899767dde3d36aa425756b11e`, 33 707 794 bytes):

| File | From the zip | sha256 |
| --- | --- | --- |
| `InterVariable.ttf` | `InterVariable.ttf` | `4989b125924991b90d05b2d16e0e388c48f7d5bb8b30539bbf9c755278d0ccaf` |
| `InterVariable.woff2` | `web/InterVariable.woff2` | `693b77d4f32ee9b8bfc995589b5fad5e99adf2832738661f5402f9978429a8e3` |
| `Inter-OFL.txt` | `LICENSE.txt` | `262481e844521b326f5ecd053e59b98c8b2da78c8ee1bdbb6e8174305e54935a` |

Inter is under the SIL Open Font License 1.1 (`Inter-OFL.txt`). The app registers the TTF for its
own process (`BundledFonts`); web pages get the WOFF2 as an `@font-face` from the page bootstrap
(`BundledFonts.pageScript`). The italic is not bundled: italic UI text is a synthesized slant.

The family, the files and the tracking are in `schemas/type-scale/type-scale.json`, pinned by
`schemas/type-scale/leo-bans.json` (`scripts/cmux-next/check-leo-bans.py`).
