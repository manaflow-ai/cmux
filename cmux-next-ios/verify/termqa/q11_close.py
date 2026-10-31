"""T-TABS-08 / V5-5: + -> New Terminal on the phone, then close its card (x) in the grid; the
Mac's `terminal list` is read every 0.5 s until the new terminal is gone (oracle only).

    TQ_BUNDLE=... python3 q11_close.py RUNS
"""
import json
import sys
import time

import tq
import v8


def mac_terms():
    out = tq._mac().cmux("terminal", "list", json_out=True)
    rows = out if isinstance(out, list) else out.get("terminals", [])
    return {t.get("id") or t.get("terminal_id"): t for t in rows}


def grid(s):
    if not [e for e in s.find(kind="Button") if (e.label or "").endswith(", tab")]:
        s.tap_q(label="Tabs", kind="Button"); time.sleep(2.5)


def one(i):
    s, m, j = tq.ctx()
    grid(s)
    before = mac_terms()
    for _ in range(3):
        s.tap(62, 812)
        if s.wait(label="New Terminal", kind="Button", timeout=4):
            break
    s.tap_q(label="New Terminal", kind="Button")
    t = time.time(); new = None
    while time.time() - t < 20 and not new:
        new = [k for k in mac_terms() if k not in before]
        time.sleep(0.5)
    time.sleep(3)
    grid(s)
    cards = [e for e in s.find(kind="Button") if (e.label or "").endswith(", tab")]
    closes = [e for e in s.find(label="Close", kind="Button")]
    # the new tab's card is the last one; its x is the Close button at the card's top-right
    card = cards[-1]
    x = [c for c in closes if abs(c.frame[1] - card.frame[1]) < 2 and card.frame[0] < c.frame[0] < card.frame[0] + card.frame[2]]
    tc = time.time()
    s.tap_el(x[0])
    gone_at = None
    while time.time() - tc < 30:
        if new and new[0] not in mac_terms():
            gone_at = time.time() - tc
            break
        time.sleep(0.5)
    confirm = bool(s.find(contains="Close") and s.find(kind="Alert"))
    cards_after = [e.label for e in s.find(kind="Button") if (e.label or "").endswith(", tab")]
    return v8.ev("close_tab", run=i, new=new, card=card.label, mac_gone_s=None if gone_at is None else round(gone_at, 2),
                 confirm_shown=confirm, cards_after=cards_after)


def main():
    for i in range(int(sys.argv[1]) if len(sys.argv) > 1 else 1):
        one(i)


if __name__ == "__main__":
    main()
