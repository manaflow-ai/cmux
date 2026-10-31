"""Shared row text for the termqa fixtures (stdlib only, Python 3.8+)."""
import sys
import time

WORDS = ("alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike "
         "november oscar papa quebec romeo sierra tango uniform victor whiskey xray yankee zulu").split()
COLORS = (31, 32, 33, 34, 35, 36, 91, 92, 93, 94, 95, 96)


def text(n, width=60):
    """Deterministic plain text for row n (no id), about `width` chars."""
    out, i = [], n
    while sum(len(w) + 1 for w in out) < width:
        out.append(WORDS[i % len(WORDS)])
        i = i * 7 + 3
    return " ".join(out)[:width]


def colored(s, n, every=10):
    """SGR-colour s in runs of `every` chars (the id column stays plain)."""
    parts = []
    for k in range(0, len(s), every):
        parts.append("\x1b[%dm%s" % (COLORS[(n + k // every) % len(COLORS)], s[k:k + every]))
    return "".join(parts) + "\x1b[0m"


def row(n, stamp=True, width=60, color=True):
    """`#%07d <send-epoch-ms> <text>` (id first, in column 0)."""
    body = text(n, width)
    head = "#%07d" % n + (" %d" % int(time.time() * 1000) if stamp else "")
    return head + " " + (colored(body, n) if color else body)


def usage(doc, argv):
    if any(a in ("-h", "--help") for a in argv[1:]):
        print(doc)
        sys.exit(0)


def arg(argv, i, default, kind=float):
    try:
        return kind(argv[i])
    except (IndexError, ValueError):
        if len(argv) > i:
            sys.exit("bad argument: %r" % argv[i])
        return default
