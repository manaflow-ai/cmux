#!/usr/bin/env python3
"""Renders a stress-loop run folder (or several) into one self-contained HTML log.

    python3 render_report.py --out report.html RUN_DIR [RUN_DIR...] [--findings findings.json]
        [--fleet fleet.json]

Screenshots are embedded as small JPEGs and each cycle's video as a small H.264 copy
(ffmpeg, 300 px wide), so the file opens anywhere. findings.json is the hand-kept
list of findings and fixes: [{"id","title","severity","path","evidence":[img paths],
"cause","fix","pr","status"}]. fleet.json lists fleet jobs: [{"what","job","sha","result"}].
"""
import argparse
import base64
import html
import json
import os
import subprocess
import tempfile

CSS = """
:root{color-scheme:light dark;--bg:#fff;--fg:#1d1d1f;--mut:#6e6e73;--card:#f5f5f7;--line:#d2d2d7;--ok:#1a7f37;--bad:#cf222e;--warn:#9a6700}
@media (prefers-color-scheme:dark){:root{--bg:#111;--fg:#f5f5f7;--mut:#a1a1a6;--card:#1c1c1e;--line:#38383a;--ok:#3fb950;--bad:#f85149;--warn:#d29922}}
body{font:14px/1.45 -apple-system,BlinkMacSystemFont,"Helvetica Neue",Arial,sans-serif;background:var(--bg);color:var(--fg);margin:0;padding:24px 32px;max-width:1400px}
h1{font-size:24px;margin:0 0 4px}h2{font-size:18px;margin:32px 0 8px;border-bottom:1px solid var(--line);padding-bottom:4px}
h3{font-size:15px;margin:20px 0 6px}.mut{color:var(--mut)}table{border-collapse:collapse;width:100%;margin:8px 0}
td,th{border:1px solid var(--line);padding:4px 6px;text-align:left;vertical-align:top;font-size:13px}th{background:var(--card)}
.pass{color:var(--ok);font-weight:600}.fail{color:var(--bad);font-weight:600}.blocked{color:var(--warn);font-weight:600}
.grid{display:flex;flex-wrap:wrap;gap:10px}.shot{background:var(--card);border-radius:8px;padding:6px;width:190px;font-size:11px}
.shot img{width:100%;border-radius:4px;display:block}.card{background:var(--card);border-radius:10px;padding:10px 14px;margin:8px 0}
video{width:300px;border-radius:6px}code{font:12px ui-monospace,Menlo,monospace}.kpi{display:inline-block;margin-right:22px}
.kpi b{font-size:20px;display:block}
"""


def img_b64(path, width=360):
    if not path or not os.path.exists(path):
        return None
    with tempfile.NamedTemporaryFile(suffix=".jpg") as t:
        subprocess.run(["sips", "-Z", str(width * 2), "-s", "format", "jpeg", "-s", "formatOptions", "60", path, "--out", t.name],
                       capture_output=True)
        data = open(t.name, "rb").read()
    return "data:image/jpeg;base64," + base64.b64encode(data).decode()


def video_b64(path):
    if not path or not os.path.exists(path):
        return None
    with tempfile.NamedTemporaryFile(suffix=".mp4") as t:
        r = subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", path, "-vf", "scale=300:-2", "-r", "12",
                            "-c:v", "libx264", "-crf", "34", "-preset", "veryfast", "-an", "-movflags", "+faststart", t.name],
                           capture_output=True)
        if r.returncode:
            return None
        data = open(t.name, "rb").read()
    return "data:video/mp4;base64," + base64.b64encode(data).decode()


def jl(path):
    if not os.path.exists(path):
        return []
    out = []
    for line in open(path):
        try:
            out.append(json.loads(line))
        except ValueError:
            pass
    return out


def esc(x):
    return html.escape(str(x if x is not None else ""))


def sparkline(values, w=520, h=60, color="#0a84ff"):
    vals = [v for v in values if v is not None]
    if len(vals) < 2:
        return ""
    lo, hi = min(vals), max(vals)
    span = (hi - lo) or 1
    pts = []
    for i, v in enumerate(values):
        if v is None:
            continue
        x = i * w / (len(values) - 1)
        y = h - (v - lo) / span * (h - 6) - 3
        pts.append(f"{x:.1f},{y:.1f}")
    return (f'<svg width="{w}" height="{h}" viewBox="0 0 {w} {h}"><polyline fill="none" stroke="{color}" stroke-width="1.5" '
            f'points="{" ".join(pts)}"/></svg> <span class="mut">{lo:.0f} to {hi:.0f}</span>')


def run_section(d, embed_video):
    meta = (jl(os.path.join(d, "meta.jsonl")) or [{}])[0]
    cycles = jl(os.path.join(d, "cycles.jsonl"))
    metrics = jl(os.path.join(d, "metrics.jsonl"))
    load = jl(os.path.join(d, "load.jsonl"))
    final = json.load(open(os.path.join(d, "final.json"))) if os.path.exists(os.path.join(d, "final.json")) else {}
    o = [f"<h2>Run {esc(os.path.basename(d.rstrip('/')))}</h2>",
         f"<p class=mut>Mac app {esc(meta.get('mac_app'))} (tag {esc(meta.get('mac_tag'))}); simulator {esc((meta.get('sim') or {}).get('name'))} "
         f"{esc((meta.get('sim') or {}).get('udid'))}; iPhone app {esc(os.path.basename(str(meta.get('ios_app'))))}</p>"]
    n = {s: sum(1 for c in cycles if c.get("status") == s) for s in ("pass", "fail", "blocked")}
    peak = max((m.get("agents", 0) for m in metrics), default=0)
    o.append(f'<div class=card><span class=kpi><b class=pass>{n["pass"]}</b>paths passed</span>'
             f'<span class=kpi><b class=fail>{n["fail"]}</b>failed</span><span class=kpi><b class=blocked>{n["blocked"]}</b>blocked</span>'
             f'<span class=kpi><b>{peak}</b>peak Codex agents</span>'
             f'<span class=kpi><b>{max((m.get("feed_posted", 0) for m in metrics), default=0)}</b>Feed events posted</span>'
             f'<span class=kpi><b>{len(final.get("hangs", []))}</b>hangs</span></div>')
    if metrics:
        o.append("<h3>Load and resource use over the run</h3><table>")
        for label, key, sub, color in (("Codex agents", "agents", None, "#0a84ff"), ("Phone app CPU %", "phone", "cpu", "#ff375f"),
                                       ("Phone app memory MB", "phone", "rss_mb", "#bf5af2"), ("Mac app CPU %", "mac", "cpu", "#ff9f0a"),
                                       ("Mac app memory MB", "mac", "rss_mb", "#30d158"), ("Host load (1 min)", "load1", None, "#64d2ff")):
            vals = [((m.get(key) or {}).get(sub) if sub else m.get(key)) for m in metrics]
            o.append(f"<tr><th style='width:180px'>{label}</th><td>{sparkline(vals, color=color)}</td></tr>")
        o.append("</table>")
    if load:
        o.append("<h3>Agents started</h3><table><tr><th>agent</th><th>kind</th><th>setup</th><th>task / error</th></tr>")
        for r in load:
            o.append(f"<tr><td>{esc(r.get('name'))}</td><td>{esc(r.get('kind'))}</td><td>{esc(r.get('setup_s'))} s</td>"
                     f"<td>{esc(r.get('error') or r.get('task'))} {esc(r.get('policy', ''))}</td></tr>")
        o.append("</table>")
    by_cycle = {}
    for c in cycles:
        by_cycle.setdefault(c.get("cycle", 0), []).append(c)
    for cy in sorted(by_cycle):
        rows = by_cycle[cy]
        ld = rows[0].get("load") or {}
        o.append(f"<h3>Cycle {cy} <span class=mut>(load: {esc(ld.get('agents', 0))} agents, {esc(ld.get('terminal', 0))} terminal / "
                 f"{esc(ld.get('gui', 0))} GUI, {esc(ld.get('feed_posted', 0))} Feed events)</span></h3>")
        vid = rows[0].get("video")
        if vid and embed_video:
            v = video_b64(os.path.join(d, vid))
            if v:
                o.append(f'<p><video controls muted src="{v}"></video> <span class=mut>cycle {cy} screen recording ({esc(vid)})</span></p>')
        o.append("<table><tr><th>path</th><th>result</th><th>time</th><th>notes</th></tr>")
        for r in rows:
            o.append(f"<tr><td>{esc(r.get('title'))}<br><code class=mut>{esc(r.get('id'))}</code></td>"
                     f"<td class={esc(r.get('status'))}>{esc(r.get('status'))}</td><td>{esc(r.get('seconds'))} s</td>"
                     f"<td>{esc(r.get('notes'))}</td></tr>")
        o.append("</table><div class=grid>")
        for r in rows:
            src = img_b64(os.path.join(d, r["screenshot"]) if r.get("screenshot") and not os.path.isabs(r["screenshot"]) else r.get("screenshot"), 190)
            if src:
                o.append(f'<div class=shot><img src="{src}"><span class={esc(r.get("status"))}>{esc(r.get("status"))}</span> {esc(r.get("id"))}</div>')
        o.append("</div>")
    if final.get("hangs"):
        o.append("<h3>Hangs</h3><pre>" + esc(json.dumps(final["hangs"], indent=1)) + "</pre>")
    if final.get("load_errors"):
        o.append("<h3>Load errors</h3><pre>" + esc(json.dumps(final["load_errors"][:40], indent=1)) + "</pre>")
    return "\n".join(o)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("runs", nargs="*")
    ap.add_argument("--out", required=True)
    ap.add_argument("--findings")
    ap.add_argument("--fleet")
    ap.add_argument("--title", default="cmux NEXT iPhone: real-user stress loop")
    ap.add_argument("--intro", default="")
    ap.add_argument("--no-video", action="store_true")
    a = ap.parse_args()
    o = [f"<!doctype html><meta charset=utf-8><title>{esc(a.title)}</title><style>{CSS}</style><h1>{esc(a.title)}</h1>", a.intro]
    if a.findings and os.path.exists(a.findings):
        fs = json.load(open(a.findings))
        o.append("<h2>Findings and fixes</h2><table><tr><th>#</th><th>finding</th><th>severity</th><th>path</th><th>cause</th>"
                 "<th>fix</th><th>status</th></tr>")
        for f in fs:
            pr = f'<a href="{esc(f["pr"])}">{esc(f.get("pr_label") or f["pr"])}</a>' if f.get("pr") else ""
            o.append(f"<tr><td>{esc(f.get('id'))}</td><td>{esc(f.get('title'))}</td><td>{esc(f.get('severity'))}</td>"
                     f"<td>{esc(f.get('path'))}</td><td>{esc(f.get('cause'))}</td><td>{esc(f.get('fix'))} {pr}</td>"
                     f"<td>{esc(f.get('status'))}</td></tr>")
        o.append("</table>")
        for f in fs:
            imgs = [img_b64(p, 260) for p in f.get("evidence", []) if p.lower().endswith((".png", ".jpg", ".jpeg"))]
            vids = [video_b64(p) for p in f.get("evidence", []) if p.lower().endswith(".mp4")] if not a.no_video else []
            if any(imgs) or any(vids):
                o.append(f"<h3>{esc(f.get('id'))}: {esc(f.get('title'))}</h3><div class=grid>")
                for i, (src, p) in enumerate(zip(imgs, [p for p in f.get("evidence", []) if p.lower().endswith((".png", ".jpg", ".jpeg"))])):
                    if src:
                        o.append(f'<div class=shot style="width:260px"><img src="{src}">{esc(os.path.basename(p))}</div>')
                for v in vids:
                    if v:
                        o.append(f'<video controls muted src="{v}"></video>')
                o.append("</div>")
    if a.fleet and os.path.exists(a.fleet):
        o.append("<h2>Fleet jobs</h2><table><tr><th>what</th><th>job</th><th>sha</th><th>result</th></tr>")
        for j in json.load(open(a.fleet)):
            o.append(f"<tr><td>{esc(j.get('what'))}</td><td><code>{esc(j.get('job'))}</code></td><td><code>{esc(j.get('sha'))}</code></td>"
                     f"<td>{esc(j.get('result'))}</td></tr>")
        o.append("</table>")
    for d in a.runs:
        o.append(run_section(d, not a.no_video))
    open(a.out, "w").write("\n".join(o))
    print(a.out)


if __name__ == "__main__":
    main()
