# Backdrop art

The bundled backdrop art is a curated set of well-known public-domain paintings and prints
(cx-t2x.7, catalog: manaflow-ai/cmuxterm-hq#1906). `art/manifest.json` at the repository root is
the one source of truth: for every work it records the Wikimedia Commons file page and original
URL, the Commons license templates, the artist's death year and the first publication year, the
picker collection, the framing hints and the SHA-256 of the rendered image.

Copyright gate: a work ships only if its artist died 70 or more years ago and it was first
published before 1931, so it is public domain in the United States as well as under life+70
terms. Works first published 1978–2002 (US copyright until 2047) do not ship.

- `art/full/<id>.avif`: every work at 1600×1000, framed for a terminal backdrop. These are
  published to `https://files.cmux.com/cmux-art/<sha256>.avif` and downloaded on first pick.
- `BackdropArt/<id>.thumb.avif`: a 480×300 thumbnail of every work, in the app.
- `BackdropArt/<id>.avif`: the full image of the dark starter set, in the app.

`scripts/cmux-next/art/render_backdrop_art.py` renders the images from the Commons downloads;
`scripts/cmux-next/art/generate_backdrop_art.py` writes `BackdropArt.swift`, the title strings and
the bundled files from the manifest (`--check` reports drift).
