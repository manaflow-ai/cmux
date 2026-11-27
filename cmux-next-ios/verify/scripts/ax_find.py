"""Print the center "x y" of an element from `axe describe-ui` JSON on stdin.

usage: axe describe-ui --udid U | python3 -I ax_find.py <label-substring> [role] [index]
Matches elements whose AXLabel contains the substring (and role, if given)
and that are on screen; prints the match at `index` (default 0).
"""
import json
import sys

sub = sys.argv[1]
role = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] else None
index = int(sys.argv[3]) if len(sys.argv) > 3 else 0
found = []


def walk(node):
    label = node.get("AXLabel") or ""
    f = node["frame"]
    if sub in label and (role is None or node.get("role") == role) and f["width"] > 1 and f["y"] >= 0 and f["y"] < 874:
        found.append((int(f["x"] + f["width"] / 2), int(f["y"] + f["height"] / 2)))
    for child in node.get("children", []):
        walk(child)


try:
    tree = json.load(sys.stdin)
except ValueError:  # axe printed an error; the caller retries
    tree = []
for n in tree:
    walk(n)
if len(found) > index:
    print(*found[index])
