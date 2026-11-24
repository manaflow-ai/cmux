#!/usr/bin/env python3
"""Phone link health read from a Mac's cmux-mobile-host log: how often the Mac refreshed its network (each one
reconnects signaling and roams every live phone link), which phone links died of their keepalive after a refresh
during their life, and the Mac's link_ready times.

  python3 -I cmux-next-ios/scripts/host_link_health.py \
    ~/Library/Application\\ Support/com.cmuxterm.app.nightly/cmux-mobile-host/cmux-mobile-host.log

Read-only; the log names sessions and device ids only, and this prints session id prefixes.
"""
import datetime as dt
import re
import sys


def ts(s):
    return dt.datetime.strptime(s[:26], "%Y-%m-%dT%H:%M:%S.%f")


def main(path):
    refresh, ups, downs = [], {}, []
    for line in open(path, errors="replace"):
        if len(line) < 27 or not line[:4].isdigit():
            continue
        t = ts(line)
        if "the Mac's network changed" in line:
            refresh.append(t)
        m = re.search(r'link up session_id="([^"]+)".*link_ready=([\d.]+)ms', line)
        if m:
            ups[m.group(1)] = (t, float(m.group(2)))
        m = re.search(r'link down session_id="([^"]+)" reason="([^"]+)"', line)
        if m:
            downs.append((t, m.group(1), m.group(2)))
    lines = []
    if len(refresh) > 1:
        hours = max((refresh[-1] - refresh[0]).total_seconds() / 3600, 1 / 60)
        gaps = sorted((b - a).total_seconds() for a, b in zip(refresh, refresh[1:]))
        lines.append(f"mac network refreshes: {len(refresh)} in {hours:.1f} h ({len(refresh) / hours:.1f}/h), "
                     f"median gap {gaps[len(gaps) // 2]:.0f} s")
    else:
        lines.append(f"mac network refreshes: {len(refresh)}")
    spanned = killed = 0
    for t, session, why in downs:
        up = ups.get(session, (None, None))[0]
        if up is None:
            continue
        hit = [r for r in refresh if up <= r <= t]
        if hit:
            spanned += 1
            if why == "keepalive timed out":
                killed += 1
                lines.append(f"  died after a refresh: {session[:8]} up {up:%H:%M:%S}, refresh {hit[-1]:%H:%M:%S}, "
                             f"down {t:%H:%M:%S} (+{(t - hit[-1]).total_seconds():.0f} s)")
    lines.append(f"phone links: {len(ups)} up, {len(downs)} down; {spanned} lived across a refresh, "
                 f"{killed} of them died of their keepalive")
    ready = sorted(v[1] for v in ups.values())
    if ready:
        lines.append(f"mac link_ready: n={len(ready)} p50={ready[len(ready) // 2]:.0f} ms max={ready[-1]:.0f} ms")
    print("\n".join(lines))


if __name__ == "__main__":
    main(sys.argv[1])
