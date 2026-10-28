"""Round-12 N3 (from the round-8 verifier's V6-1): draft 1, 3 and 6 lines, keyboard up and down;
bottom pin after the composer draft grows and shrinks 6 -> 3 -> 1 lines.
Round-8 verifier, V6-1: bottom pin after the composer draft shrinks 6 -> 3 -> 1 lines.
A reverse-video bar is the last terminal row (typed on the phone); v6pin.py measures the
bar's bottom edge against the first non-background pixel row under it (the composer card).

    TQ_BUNDLE=dev.cmux.mobile.tq10 python3 q12.py v12_pin TAG [TAB=e2e-t2]
"""
import json
import os
import subprocess
import sys
import time

import tq
import v8
import v6pin
from PIL import Image
from v8 import ev, ctx
from v8_hold import open_tab

SIX = ("one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen "
       "seventeen eighteen nineteen twenty twentyone twentytwo twentythree twentyfour twentyfive twentysix "
       "twentyseven twentyeight twentynine thirty thirtyone thirtytwo thirtythree thirtyfour thirtyfive "
       "thirtysix thirtyseven thirtyeight thirtynine forty fortyone fortytwo fortythree fortyfour")


def card_h(s):
    f = s.find(ident="terminal.composer.field")
    return round(f[0].frame[3], 1) if f else None


def measure(s, name, out):
    raw = v8.shot(f"{name}")
    f = s.find(ident="terminal.composer.field")
    r = v6pin.analyze(Image.open(raw))
    r.update({"name": name, "field_h": card_h(s), "field_top": round(f[0].frame[1], 1) if f else None, "kb": bool(s.keyboard())})
    out.append(r)
    print(json.dumps(r), flush=True)


def main():
    if sys.argv[3:4] == ["fresh"]:
        return fresh()
    tag = sys.argv[1]
    tab = sys.argv[2] if len(sys.argv) > 2 else "e2e-t2"
    s, m, j = ctx()
    if not s.find(ident="terminal.composer.field"):
        j.open_seed_workspace()
    open_tab(s, tab)
    t0s = time.strftime("%Y-%m-%d %H:%M:%S")
    tq.paste_composer("seq 1 300; printf '\\e[7m%*s\\e[0m' $COLUMNS ''; read x")
    time.sleep(2)
    out = []
    measure(s, f"{tag}-1line-kbup", out)
    tq.paste_composer(SIX, send=False)
    time.sleep(1.5)
    measure(s, f"{tag}-6lines-kbup", out)
    j.hide_keyboard(); time.sleep(1.5)
    measure(s, f"{tag}-6lines-kbdown", out)
    s.tap_q(ident="terminal.composer.field"); time.sleep(1.2)
    k = s.keyboard()
    for target in (3, 1):
        for _ in range(12):
            h = card_h(s)
            lines = out[-1]["field_h"]
            if h is not None and h <= {3: 80, 1: 40}[target]:
                break
            s.long_press(*k["delete"].center, seconds=2.2)
            time.sleep(0.6)
        time.sleep(1.5)
        measure(s, f"{tag}-shrunk{target}-kbup", out)
        j.hide_keyboard(); time.sleep(1.5)
        measure(s, f"{tag}-shrunk{target}-kbdown", out)
        time.sleep(5)
        measure(s, f"{tag}-shrunk{target}-kbdown-5s", out)
        s.tap_q(ident="terminal.composer.field"); time.sleep(1.2)
        k = s.keyboard()
    tq.composer_clear(); time.sleep(0.5)
    j.keybar("Control C"); time.sleep(0.5)
    j.hide_keyboard()
    v8.applog(t0s, os.path.join(v8.V6, f"{tag}.log"), 'subsystem == "dev.cmux.mobile" AND eventMessage CONTAINS "pin:"')
    json.dump(out, open(os.path.join(v8.V6, f"{tag}-pin.json"), "w"), indent=1)
    ev("pin", tag=tag, gaps=[(r["name"], r.get("gap_pt"), r.get("bar_h"), r["field_h"]) for r in out])


THREE = SIX[:90]
ONE = "one two three"


def fresh():
    """Each draft size typed fresh (1, 3, 6 lines), keyboard up and down: TAG TAB fresh."""
    tag = sys.argv[1]
    tab = sys.argv[2] if len(sys.argv) > 2 else "e2e-t2"
    s, m, j = ctx()
    if not s.find(ident="terminal.composer.field"):
        j.open_seed_workspace()
    open_tab(s, tab)
    t0s = time.strftime("%Y-%m-%d %H:%M:%S")
    tq.paste_composer("clear; seq 1 300; printf '\\e[7m%*s\\e[0m' $COLUMNS ''; read x")
    time.sleep(2)
    out = []
    for name, draft in (("1line", ONE), ("3lines", THREE), ("6lines", SIX)):
        v8.clear_composer(); time.sleep(0.5)
        tq.paste_composer(draft, send=False)
        time.sleep(1.5)
        measure(s, f"{tag}-{name}-kbup", out)
        j.hide_keyboard(); time.sleep(1.5)
        measure(s, f"{tag}-{name}-kbdown", out)
        s.tap_q(ident="terminal.composer.field"); time.sleep(1.2)
    tq.composer_clear(); time.sleep(0.5)
    j.keybar("Control C"); time.sleep(0.5)
    j.hide_keyboard()
    v8.applog(t0s, os.path.join(v8.V6, f"{tag}.log"), 'subsystem == "dev.cmux.mobile" AND eventMessage CONTAINS "pin:"')
    json.dump(out, open(os.path.join(v8.V6, f"{tag}-pin.json"), "w"), indent=1)
    ev("pin", tag=tag, gaps=[(r["name"], r.get("gap_pt"), r.get("bar_h"), r["field_h"]) for r in out])


if __name__ == "__main__":
    main()
