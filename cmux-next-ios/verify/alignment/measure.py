"""List alignment measurements of the cmux-next iPhone app, screen by screen, on a rig.

Runs ON the cmux mini that hosts the rig (rig.py's hidden tagged Mac app + one headless
simulator). Drives the simulator with real HID touches (AXe), reads the AX tree and
screenshots, and measures for every list screen where each section header, footer,
inline label, row title, gutter mark (dot, chevron, icon) and separator starts, in points.

    python3 measure.py --app PATH.app --out DIR [--udid UDID] [--rig DIR]
                       [--appearances light,dark] [--sizes large,extra-extra-large]
                       [--screens a,b,...] [--keep-install]

--app is (re)installed fresh and signed in with the DEBUG dev credential (email 42);
--keep-install measures the app already installed. The rig Mac is chosen in the
Workspaces filter by its device id (rig.py device-id in --rig).

Writes, per (appearance, size, screen, page): DIR/<appearance>-<size>/<screen>[-pN].png and
.json (raw AX + OCR + measurements), DIR/results.json and DIR/summary.md (header x's vs
row title x's per screen). See analyze.py for what each number means.
"""
import argparse
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "../e2e"))
sys.path.insert(0, HERE)
from analyze import analyze, bands_for, regions, scan, summary, visible  # noqa: E402
from journey import BUNDLE, Journey  # noqa: E402
from sim import Sim  # noqa: E402

ALIGNSCAN = os.path.expanduser("~/hdralign/bin/alignscan")


def ensure_alignscan():
    src = os.path.join(HERE, "alignscan.swift")
    if not os.path.exists(ALIGNSCAN) or os.path.getmtime(ALIGNSCAN) < os.path.getmtime(src):
        os.makedirs(os.path.dirname(ALIGNSCAN), exist_ok=True)
        subprocess.run(["xcrun", "swiftc", "-O", "-o", ALIGNSCAN, src], check=True, timeout=600)


class Measure:
    def __init__(self, sim, journey, out, log, device_id):
        self.sim, self.j, self.out, self.log, self.device_id = sim, journey, out, log, device_id
        self.results = {}
        self.variant = None

    # ---- capture --------------------------------------------------------------
    def settled_tree(self, tries=6):
        """An AX tree that stopped changing (two reads with the same frames)."""
        prev = None
        for _ in range(tries):
            t = self.sim.tree()
            sig = [(e.kind, e.label, tuple(round(v) for v in e.frame)) for e in t]
            if sig == prev and len(t) > 1:
                return t
            prev = sig
            time.sleep(0.6)
        return t

    def capture(self, name, top=None, bottom=None, note=None, start_ident=None):
        """Measures the screen as it is. start_ident: only that element and the ones after it
        in the AX tree (a menu or drawer drawn over the screen), OCR clipped to their bounds."""
        d = os.path.join(self.out, self.variant)
        os.makedirs(d, exist_ok=True)
        tree = self.settled_tree()
        clip = None
        if start_ident:
            i = next((k for k, e in enumerate(tree) if e.ident == start_ident or e.label == start_ident), None)
            if i is not None:
                tree = [tree[0]] + tree[i:]
                fr = [e.frame for e in tree[1:] if e.frame[2] > 0 and e.frame[3] > 0
                      and not (e.frame[2] >= 402 * 0.9 and e.frame[3] >= 874 * 0.9)]
                if fr:
                    x0 = min(f[0] for f in fr); y0 = min(f[1] for f in fr)
                    clip = (x0, y0, max(f[0] + f[2] for f in fr) - x0, max(f[1] + f[3] for f in fr) - y0)
        t0, b0 = regions(tree)
        top = t0 if top is None else top
        bottom = b0 if bottom is None else bottom
        png = os.path.join(d, f"{name}.png")
        subprocess.run(["xcrun", "simctl", "io", self.sim.udid, "screenshot", png], capture_output=True, timeout=60)
        els = visible(tree, top, bottom)
        _, _, bands = bands_for(els, top, bottom)
        sc = scan(ALIGNSCAN, png, bands)
        m = analyze(tree, sc, top, bottom, clip)
        m["clip"] = clip
        s = summary(m)
        doc = {"screen": name, "variant": self.variant, "note": note, "summary": s, "measure": m,
               "ax": [{"kind": e.kind, "label": e.label, "ident": e.ident, "value": e.value,
                       "frame": [round(v, 2) for v in e.frame]} for e in els],
               "ocr": sc["ocr"], "pixel_separators": sc["separators"]}
        json.dump(doc, open(os.path.join(d, f"{name}.json"), "w"), indent=1, default=str)
        self.results.setdefault(self.variant, {})[name] = {"summary": s, "note": note}
        self.log(f"  {self.variant}/{name}: headers {s['header_x']} rows {s['row_title_x']} marks {s['mark_x'][:6]} "
                 f"labels {s['label_x'][:6]} seps {s['separator_x0'][:4]}")
        return m

    def capture_pages(self, name, pages=3, note=None, drag=(650, 250)):
        """Captures a scrolling list page by page (until it stops moving or `pages`)."""
        last = None
        for p in range(pages):
            m = self.capture(name if p == 0 else f"{name}-p{p + 1}", note=note)
            sig = [r.get("title") for r in m["rows"]] + [h["text"] for h in m["headers"]]
            if sig == last:
                os.remove(os.path.join(self.out, self.variant, f"{name}-p{p + 1}.png"))
                os.remove(os.path.join(self.out, self.variant, f"{name}-p{p + 1}.json"))
                self.results[self.variant].pop(f"{name}-p{p + 1}", None)
                break
            last = sig
            if p + 1 < pages:
                self.sim.drag(201, drag[0], 201, drag[1], 0.5, 25, 0.3)
                time.sleep(1.0)
        # Back to the top.
        for _ in range(pages):
            self.sim.drag(201, 250, 201, 750, 0.3, 15, 0.1)
        time.sleep(0.6)
        self.expand_tabs()

    def skip(self, name, why):
        self.results.setdefault(self.variant, {})[name] = {"skipped": why}
        self.log(f"  {self.variant}/{name}: SKIPPED {why}")

    # ---- navigation helpers -------------------------------------------------------
    def expand_tabs(self):
        """A scrolled page minimizes the iOS 26 tab bar to one button (the current tab):
        scroll the page back up, then tap that button, until every tab shows."""
        for i in range(4):
            tabs = [e for e in self.sim.find(kind="RadioButton") if e.frame[1] > 760]
            if len(tabs) >= 4 or self.sim.find(label="Close teams"):
                return
            if i % 2 == 0:
                for _ in range(2):
                    self.sim.drag(201, 250, 201, 750, 0.3, 15, 0.1)
            elif tabs:
                self.sim.tap_el(tabs[0])
            time.sleep(0.8)

    def tab(self, name):
        self.sim.close_drawer()
        self.expand_tabs()
        self.j.tab(name)

    def to_list(self):
        self.expand_tabs()
        self.j.back_to_list()

    def top_of_list(self):
        for _ in range(3):
            self.sim.drag(201, 250, 201, 750, 0.3, 15, 0.1)
        time.sleep(0.5)

    def back(self):
        b = [e for e in self.sim.find(kind="Button") if (e.label == "Back" or e.ident == "BackButton") and e.frame[0] >= 0]
        if b:
            self.sim.tap_el(b[0])
            time.sleep(1.0)
            return True
        return False

    def choose_mac(self):
        """Workspaces filter > the rig Mac (by device id)."""
        self.to_list()
        f = self.sim.wait(ident="workspaces.filter", timeout=30)
        if not f:
            raise RuntimeError("no Workspaces filter")
        if self.device_id and self.device_id in (f.value or ""):
            return
        self.sim.press(*f.center, hold=0.1)
        item = self.sim.wait(ident=f"workspaces.filter.{self.device_id}", timeout=10)
        if not item:
            self.sim.tap(60, 450)
            raise RuntimeError(f"rig Mac {self.device_id} not in the filter menu")
        self.sim.press(*item.center, hold=0.1)
        time.sleep(2.0)

    def wait_rows(self, timeout=60):
        return self.sim.wait(ident="workspace.row.*", timeout=timeout)

    # ---- screens ------------------------------------------------------------------------
    def s_workspaces(self):
        self.to_list()
        self.top_of_list()
        if not self.wait_rows(60):
            return self.skip("workspaces", "no workspace rows within 60 s")
        time.sleep(2.0)
        self.capture_pages("workspaces", pages=4, note="Needs You, Pinned, groups (expanded and collapsed), emoji title")

    def s_filter_menu(self):
        self.to_list()
        f = self.sim.wait(ident="workspaces.filter", timeout=20)
        if not f:
            return self.skip("filter-menu", "no Filter button")
        self.sim.press(*f.center, hold=0.1)
        if not self.sim.wait(ident="workspaces.filter.all", timeout=10):
            return self.skip("filter-menu", "menu did not open")
        time.sleep(1.2)
        self.capture("filter-menu", top=0, bottom=874, note="Mac filter menu", start_ident="workspaces.filter.all")
        self.sim.tap(60, 450)
        time.sleep(0.8)

    def s_home(self):
        self.to_list()
        self.tab("Home")
        self.sim.wait(ident="home.chief", timeout=20)
        time.sleep(2.0)
        self.capture_pages("home", pages=3)

    def s_chief_info(self):
        self.to_list()
        self.tab("Home")
        row = self.sim.wait(ident="home.chief.mac", timeout=20) or self.sim.wait(ident="home.chief", timeout=5)
        if not row:
            return self.skip("chief-info", "no Chief row on Home")
        self.sim.tap_el(row)
        info = None
        # The conversation's header name opens Chief info (a sheet).
        for q in (dict(ident="conversation.header.name"), dict(ident="conversation.header.trailing"), dict(label="Chief info")):
            info = self.sim.wait(timeout=8, **q)
            if info:
                break
        if not info:
            self.back()
            return self.skip("chief-info", "no Chief info button in the conversation")
        self.sim.tap_el(info)
        time.sleep(2.0)
        self.capture_pages("chief-info", pages=3)
        done = self.sim.find(ident="chief.settings.done") or self.sim.find(label="Done", kind="Button")
        if done:
            self.sim.tap_el(done[0])
            time.sleep(1.0)
        self.to_list()

    def s_feed(self):
        self.to_list()
        self.tab("Feed")
        time.sleep(3.0)
        self.capture_pages("feed", pages=3)

    def s_settings(self):
        self.to_list()
        self.tab("Settings")
        self.top_of_list()
        time.sleep(1.0)
        self.capture_pages("settings", pages=4)

    def settings_rows(self):
        """Every Settings row that opens a page (a chevron row), top to bottom, by label."""
        self.top_of_list()
        labels, seen = [], set()
        for _ in range(5):
            els = self.sim.tree()
            chevrons = [e for e in els if e.kind == "Image" and (e.ident or "").startswith("chevron.")]
            for r in self.sim.find(kind="Button", elements=els):
                x, y, w, h = r.frame
                if w < 300 or not (100 < y + h / 2 < 780):
                    continue
                if any(abs(c.center[1] - (y + h / 2)) < h / 2 and c.frame[0] > x + w * 0.8 for c in chevrons):
                    first = (r.label or "").split(",")[0]
                    if first and first not in seen:
                        seen.add(first)
                        labels.append(first)
            self.sim.drag(201, 650, 201, 300, 0.4, 20, 0.2)
            time.sleep(0.6)
        self.top_of_list()
        return labels

    def open_settings_row(self, first):
        for _ in range(8):
            hit = [e for e in self.sim.find(kind="Button") if (e.label or "").split(",")[0] == first
                   and 110 < e.center[1] < 780 and e.frame[2] > 300]
            if hit:
                self.sim.tap_el(hit[0])
                time.sleep(1.5)
                return True
            self.sim.drag(201, 650, 201, 350, 0.4, 20, 0.2)
            time.sleep(0.6)
        return False

    def s_settings_pages(self):
        self.to_list()
        self.tab("Settings")
        rows = self.settings_rows()
        self.log(f"  settings pages: {rows}")
        external = {"Help", "Report a problem", "Terms of Use", "Privacy Policy"}
        if getattr(self, "only_pages", None):
            rows = [r for r in rows if any(r.startswith(p) for p in self.only_pages)]
        for first in rows:
            slug = "settings-" + "".join(c if c.isalnum() else "-" for c in first.lower()).strip("-")
            if first in external:
                self.skip(slug, "opens a web page (Safari view), not a list")
                continue
            self.tab("Settings")
            self.top_of_list()
            if not self.open_settings_row(first):
                self.skip(slug, "row not found")
                continue
            if self.sim.find(label="Settings", kind="Heading") and not self.sim.find(kind="Button", label="Back") \
                    and not self.sim.find(ident="BackButton"):
                self.skip(slug, "did not open a page")
                continue
            time.sleep(1.5)
            self.capture_pages(slug, pages=2)
            if first.startswith("Devices") or slug == "settings-devices":
                pass
            self.back()
            if not self.sim.find(label="Settings", kind="Heading"):
                self.back()

    def s_sidebar(self):
        self.to_list()
        t = self.sim.wait(label="Teams", kind="Button", timeout=10)
        if not t:
            return self.skip("sidebar-teams", "no Teams button")
        self.sim.tap_el(t)
        if not self.sim.wait(label="Close teams", timeout=8):
            return self.skip("sidebar-teams", "drawer did not open")
        time.sleep(1.2)
        self.capture("sidebar-teams", top=0, bottom=874, note="team drawer")  # the drawer is the whole tree
        self.sim.close_drawer()

    def run(self, names):
        for n in names:
            fn = getattr(self, "s_" + n.replace("-", "_"), None)
            if not fn:
                self.skip(n, "unknown screen")
                continue
            self.log(f"--- {self.variant} {n}")
            try:
                fn()
            except Exception as e:  # one screen's failure never stops the run
                self.skip(n, f"error: {str(e)[:300]}")
                try:
                    self.to_list()
                except Exception:
                    pass


SCREENS = ["workspaces", "filter-menu", "home", "chief-info", "feed", "settings", "settings-pages", "sidebar"]


def write_summary(out, results, meta):
    lines = [f"# List alignment: {meta.get('label') or ''}", "",
             f"App: `{meta['app']}`  ", f"Simulator: {meta['udid']}  ", f"Run: {meta['started']}", "",
             "x in points from the screen's left edge. *header*: section headers' text ink; *row title*: "
             "row titles' ink (AX x in brackets when different); *marks*: ink left of the title (dots, "
             "chevrons, icons); *labels*: footers and loose text; *separators*: hairline start.", ""]
    for variant, screens in results.items():
        lines += [f"## {variant}", "", "| screen | headers | row titles | marks | labels | separators |",
                  "| --- | --- | --- | --- | --- | --- |"]
        for name, r in screens.items():
            if "skipped" in r:
                lines.append(f"| {name} | skipped: {r['skipped']} | | | | |")
                continue
            s = r["summary"]
            ax = [v for v in s["row_title_ax_x"] if v not in s["row_title_x"]]
            hdr = ", ".join(f"{t} {x}" for t, x in s["headers"]) or "-"
            lines.append(f"| {name} | {hdr} | {', '.join(map(str, s['row_title_x'])) or '-'}"
                         f"{' [' + ', '.join(map(str, ax)) + ']' if ax else ''} | {', '.join(map(str, s['mark_x'][:8])) or '-'} | "
                         f"{', '.join(map(str, s['label_x'][:8])) or '-'} | {', '.join(map(str, s['separator_x0'][:6])) or '-'} |")
        lines.append("")
    open(os.path.join(out, "summary.md"), "w").write("\n".join(lines))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--udid", default=None, help="default: ~/hdralign/SIM_UDID")
    ap.add_argument("--rig", default=os.path.expanduser("~/hdralign/rigmac"), help="rig.py folder of the rig Mac")
    ap.add_argument("--appearances", default="light,dark")
    ap.add_argument("--sizes", default="large,extra-extra-large")
    ap.add_argument("--screens", default=",".join(SCREENS))
    ap.add_argument("--variants", default=None,
                    help="appearance:size list, e.g. light:large,dark:large,light:extra-extra-large (overrides --appearances/--sizes)")
    ap.add_argument("--settings-pages", default=None, help="only these Settings rows (comma list of first words)")
    ap.add_argument("--keep-install", action="store_true")
    ap.add_argument("--label", default="")
    a = ap.parse_args()
    os.environ.setdefault("DEVELOPER_DIR", "/Applications/Xcode_26.6.app/Contents/Developer")
    os.environ["PATH"] = os.path.expanduser("~/r13-tools/axe") + ":" + os.environ["PATH"]
    udid = a.udid or open(os.path.expanduser("~/hdralign/SIM_UDID")).read().strip()
    os.makedirs(a.out, exist_ok=True)
    ensure_alignscan()
    logf = open(os.path.join(a.out, "run.log"), "a")

    def log(msg):
        line = f"{time.strftime('%H:%M:%S')} {msg}"
        print(line, flush=True)
        logf.write(line + "\n")
        logf.flush()

    device_id = subprocess.run(["python3", "rig_hdr.py", "device-id"], cwd=a.rig, capture_output=True, text=True).stdout.strip()
    sim = Sim(udid, os.path.join(a.out, "nav"))
    j = Journey(sim, None, a.out, os.path.abspath(a.app), log)
    meta = {"app": os.path.abspath(a.app), "udid": udid, "device_id": device_id, "started": time.strftime("%Y-%m-%d %H:%M:%S"),
            "label": a.label}
    try:
        meta["app_info"] = subprocess.run(["plutil", "-extract", "CFBundleVersion", "raw", os.path.join(a.app, "Info.plist")],
                                          capture_output=True, text=True).stdout.strip()
    except Exception:
        pass
    if not a.keep_install:
        log(str(j.s_fresh_install()))
        log(str(j.s_sign_in()))
        try:
            log(str(j.s_choose_space()))
        except Exception as e:  # a dropped Continue tap on a loaded mini: tap it again
            log(f"choose space: {e}; tapping Continue again")
            sim.tap_q(label="Continue", kind="Button", timeout=10)
            if not sim.wait(label="Workspaces", kind="RadioButton", timeout=30):
                raise
    m = Measure(sim, j, a.out, log, device_id)
    m.variant = "setup"
    m.choose_mac()
    m.wait_rows(90)
    m.results.pop("setup", None)
    screens = [s for s in a.screens.split(",") if s]
    m.only_pages = [p for p in (a.settings_pages or "").split(",") if p] or None
    variants = [tuple(v.split(":")) for v in a.variants.split(",")] if a.variants else \
        [(ap_, sz) for sz in a.sizes.split(",") for ap_ in a.appearances.split(",")]
    for appearance, size in variants:
        r = subprocess.run(["xcrun", "simctl", "ui", udid, "content_size", size], capture_output=True, text=True)
        meta.setdefault("content_size", {})[size] = (r.returncode, (r.stderr or r.stdout).strip()[:200])
        got = subprocess.run(["xcrun", "simctl", "ui", udid, "content_size"], capture_output=True, text=True).stdout.strip()
        log(f"content_size {size}: rc {r.returncode}, now {got}")
        if True:
            subprocess.run(["xcrun", "simctl", "ui", udid, "appearance", appearance], capture_output=True)
            # A relaunch, so every screen draws at the new size from scratch.
            sim.terminate(BUNDLE)
            sim.launch(BUNDLE)
            time.sleep(4)
            m.variant = f"{appearance}-{size}"
            try:
                m.choose_mac()
            except Exception as e:
                log(f"choose_mac: {e}")
            m.run(screens)
            json.dump({"meta": meta, "results": m.results}, open(os.path.join(a.out, "results.json"), "w"), indent=1, default=str)
            write_summary(a.out, m.results, meta)
    subprocess.run(["xcrun", "simctl", "ui", udid, "content_size", "large"], capture_output=True)
    subprocess.run(["xcrun", "simctl", "ui", udid, "appearance", "light"], capture_output=True)
    json.dump({"meta": meta, "results": m.results}, open(os.path.join(a.out, "results.json"), "w"), indent=1, default=str)
    write_summary(a.out, m.results, meta)
    log(f"done -> {a.out}/summary.md")


if __name__ == "__main__":
    main()
