"""Prunes in an app log: the page's row count (pin: ... rows N) dropping by more than 100."""
import re
import sys


def prunes(path):
    out, last = [], None
    for line in open(path, errors="replace"):
        m = re.search(r"rows (\d+)\)", line)
        if not m:
            continue
        n = int(m.group(1))
        if last is not None and n < last - 100:
            out.append((line[11:23], last, n))
        last = n
    return out


if __name__ == "__main__":
    p = prunes(sys.argv[1])
    print(len(p), p)
