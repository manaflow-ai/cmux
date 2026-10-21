"""scroll_smoothness.py <scroll.csv>... : per fling, direction reversals and
one-frame spikes in the per-frame shift (a stale or misplaced frame shows as
a jump and its correction), plus the residual after alignment."""
import csv, sys
for path in sys.argv[1:]:
    rows = list(csv.DictReader(open(path)))
    sh = [int(r["shift_px"]) for r in rows]
    res = [float(r["residual"]) for r in rows]
    mv = [i for i, s in enumerate(sh) if s != 0]
    issues, sign = [], None
    for k, i in enumerate(mv):
        s = sh[i]
        if sign is not None and (s > 0) != (sign > 0):
            issues.append(("reversal", i, sh[max(0, i - 2):i + 3]))
        sign = s
        if 0 < k < len(mv) - 1:
            a, b = abs(sh[mv[k - 1]]), abs(sh[mv[k + 1]])
            if abs(s) > 1.6 * max(a, b) + 20:
                issues.append(("spike", i, sh[max(0, i - 2):i + 3], res[i]))
    print(f"{path}: moving pairs={len(mv)} max residual={max(res):.2f} issues={issues}")
