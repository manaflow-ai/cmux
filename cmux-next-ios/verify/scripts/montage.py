"""montage.py <out.png> <frame.png>... : side-by-side strip with file names (ms) as labels."""
import sys
from PIL import Image, ImageDraw
out, files = sys.argv[1], sys.argv[2:]
ims = [Image.open(f).convert("RGB") for f in files]
w, h = ims[0].size
sheet = Image.new("RGB", (w * len(ims) + 4 * (len(ims) - 1), h + 20), (255, 0, 255))
d = ImageDraw.Draw(sheet)
for i, (im, f) in enumerate(zip(ims, files)):
    sheet.paste(im, (i * (w + 4), 20))
    d.text((i * (w + 4) + 4, 4), f.split("/")[-1], fill=(255, 255, 255))
sheet.save(out)
