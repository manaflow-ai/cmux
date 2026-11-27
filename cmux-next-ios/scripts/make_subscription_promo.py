#!/usr/bin/env python3
"""Draw the subscription promotional images in AppStoreReview/subscriptions/.

App Store Connect wants one 1024x1024 RGB image (no alpha) per subscription
(`asc validate`'s subscriptions.images.recommended). Each is the app's chevron
mark on a white tile over the plan's tint, with the plan's name. The checked-in
PNGs are this script's output; rerun it after changing a plan's name or tint:

    python3 cmux-next-ios/scripts/make_subscription_promo.py

Needs Pillow and DejaVu Sans Bold (fonts-dejavu-core). Not run in CI.
"""

from __future__ import annotations

import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

REPO = Path(__file__).resolve().parents[2]
OUT = REPO / "cmux-next-ios" / "AppStoreReview" / "subscriptions"
CHEVRON = REPO / "AppIcon.icon" / "Assets" / "cmux-icon-chevron 2.png"
FONT = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
PLANS = {
    "next_plus": ("cmux Plus", (46, 111, 230)),
    "next_pro": ("cmux Pro", (124, 77, 255)),
    "next_max": ("cmux Max", (16, 16, 20)),
}


def draw(label: str, tint: tuple[int, int, int], chevron: Image.Image, font: ImageFont.FreeTypeFont) -> Image.Image:
    base = Image.new("RGB", (1024, 1024), tint)
    shade = Image.linear_gradient("L").resize((1024, 1024)).point(lambda v: int(v * 0.55))
    base = Image.composite(Image.new("RGB", (1024, 1024), (0, 0, 0)), base, shade)
    mark = chevron.copy()
    mark.thumbnail((440, 440))
    tile = Image.new("RGBA", (520, 520), (0, 0, 0, 0))
    ImageDraw.Draw(tile).rounded_rectangle((0, 0, 519, 519), radius=118, fill=(255, 255, 255, 255))
    tile.alpha_composite(mark, ((520 - mark.width) // 2, (520 - mark.height) // 2))
    base.paste(tile, (252, 150), tile)
    text = ImageDraw.Draw(base)
    text.text(((1024 - text.textlength(label, font=font)) / 2, 760), label, font=font, fill=(255, 255, 255))
    return base


def main() -> int:
    chevron = Image.open(CHEVRON).convert("RGBA")
    font = ImageFont.truetype(FONT, 104)
    for key, (label, tint) in PLANS.items():
        path = OUT / f"promo-{key}.png"
        draw(label, tint, chevron, font).save(path, optimize=True)
        print(path.relative_to(REPO))
    return 0


if __name__ == "__main__":
    sys.exit(main())
