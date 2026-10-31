"""V6-5 (a tab fell about 500 items behind the Mac and froze) and D10 (a returned tab lags):
real Codex in three terminal tabs for MINUTES, every command typed on the phone. Each
cycle the phone opens the next tab through the grid, waits RETURN_S, then samples that
tab's highest numbered item on the phone (OCR) and on the Mac (its screen) a few times.
A tab whose phone item stays behind the Mac by more than STALL_ITEMS while the Mac
advances, for two samples in a row, is a V6-5 divergence; the lag right after a return
is D10. When a Codex finishes, it is prompted again (from the phone) so all three keep
streaming.

    python3 v65.py setup            third tab e2e-t3 on the Mac (CLI), Codex started in each tab from the phone
    python3 v65.py run MINUTES      the cycle; json lines to TQ_RAW/v65-<time>.jsonl, summary to design/terminal/v65/
"""
import json
import os
import sys
import time

import reg
import tq
from tq import ctx, load, save, log

OUT = os.path.abspath(os.path.join(tq.HERE, "../design/terminal/v65"))
TABS = ("e2e-t1", "e2e-t2", "e2e-t3")
PROMPT = ("Count from 1 to 2500. Write one item per line as 'N. ' followed by a short sentence "
          "about the number N. No tools, no preamble.")
RETURN_S = 1.0
STALL_ITEMS = 40


def term_ids():
    st = load()
    return {"e2e-t1": st["seed"]["term1"], "e2e-t2": st["seed"]["term2"], "e2e-t3": st["seed"].get("term3")}


def setup():
    sim, mac, j = ctx()
    st = load()
    if not st["seed"].get("term3"):
        t3 = mac.cmux("tab", "create", "terminal", "--workspace", st["seed"]["ws"], json_out=True)["value"]
        mac.cmux("tab", t3["tab_id"], "rename", "e2e-t3")
        st["seed"].update(term3=t3["terminal_id"], tab3=t3["tab_id"])
        save(st)
        time.sleep(3)
    for name in TABS:
        reg.open_tab(sim, name)
        st = load(); st["term"] = term_ids()[name]; save(st)
        reg.leave_codex(j)
        tq.paste_composer(f"clear; mkdir -p {reg.CODEX_DIR} && cd {reg.CODEX_DIR} && codex --yolo")
        if not reg.wait_mac(lambda t: "Ask Codex" in t, 60):
            raise RuntimeError(f"{name}: codex prompt never showed")
        time.sleep(1)
        tq.paste_composer(PROMPT)
        log(f"{name}: Codex prompted")
    j.hide_keyboard()


def sample(sim, term):
    tq_term = load()
    tq_term["term"] = term
    save(tq_term)
    t0 = time.time()
    mac = tq.max_item(tq.mac_screen(term))
    phone = tq.max_item("\n".join(o[4] for o in sim.ocr()))
    return {"t": round(t0, 2), "mac": mac, "phone": phone, "working": None}


def run(minutes):
    sim, mac, j = ctx()
    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(tq.RAW, f"v65-{time.strftime('%m%d-%H%M%S')}.jsonl")
    ids = term_ids()
    behind = {n: 0 for n in TABS}
    events, t_end, cycle = [], time.time() + minutes * 60, 0
    with open(path, "w") as f:
        while time.time() < t_end:
            name = TABS[cycle % len(TABS)]
            cycle += 1
            t_open = time.time()
            reg.open_tab(sim, name)
            time.sleep(RETURN_S)
            rows = []
            for k in range(4):
                s = sample(sim, ids[name])
                s.update(tab=name, cycle=cycle, k=k, since_open=round(s["t"] - t_open, 2))
                rows.append(s)
                f.write(json.dumps(s) + "\n"); f.flush()
                time.sleep(1.0)
            gaps = [r["mac"] - r["phone"] for r in rows if r["mac"] is not None and r["phone"] is not None]
            mac_moved = rows[-1]["mac"] is not None and rows[0]["mac"] is not None and rows[-1]["mac"] > rows[0]["mac"]
            phone_moved = rows[-1]["phone"] is not None and rows[0]["phone"] is not None and rows[-1]["phone"] > rows[0]["phone"]
            stuck = bool(gaps) and min(gaps) > STALL_ITEMS and mac_moved and not phone_moved
            behind[name] = behind[name] + 1 if stuck else 0
            ev = {"cycle": cycle, "tab": name, "gaps": gaps, "mac_moved": mac_moved, "phone_moved": phone_moved,
                  "divergence": behind[name] >= 2}
            events.append(ev)
            if ev["divergence"]:
                tq.shot(f"v65-divergence-{name}-{cycle}")
                log(f"V6-5 DIVERGENCE {name}: {gaps}")
            # A finished Codex is prompted again from the phone.
            text = tq.mac_screen(ids[name])
            if not reg.codex_working(text) and "Ask Codex" in text:
                tq.paste_composer(PROMPT)
                j.hide_keyboard()
    first_gap = [e["gaps"][0] for e in events if e["gaps"]]
    summary = {"minutes": minutes, "cycles": cycle, "samples": path, "divergences": [e for e in events if e["divergence"]],
               "return_gap_items": {"n": len(first_gap), "max": max(first_gap) if first_gap else None,
                                    "p50": sorted(first_gap)[len(first_gap) // 2] if first_gap else None},
               "load": tq.load_avg(), "time": time.strftime("%Y-%m-%d %H:%M:%S")}
    out = os.path.join(OUT, f"run-{time.strftime('%m%d-%H%M%S')}.json")
    json.dump(summary, open(out, "w"), indent=1)
    print(json.dumps(summary, indent=1))


if __name__ == "__main__":
    if sys.argv[1] == "setup":
        setup()
    else:
        run(float(sys.argv[2]))
