"""One-off property run (not committed): the python check at 8545a9d0 vs the syn check, on generated chains."""
import importlib.util, pathlib, random, sys

HERE = pathlib.Path(__file__).resolve().parent
REL = "cmux-tui/crates/acpmux/src/chain.rs"


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def gen(out, count=4000, seed=41418):
    prop = load(HERE / "check-test-hooks-property.py", "prop")
    base = load(HERE / "check-test-hooks.py", "base")
    out.mkdir(parents=True, exist_ok=True)
    rng = random.Random(seed)
    for i in range(count):
        path = out / f"{i:04}.rs"
        path.write_text(prop.Chain(rng).generate(), encoding="utf-8")
        (out / f"{i:04}.base").write_text("1" if base.judge_file(path, REL) else "0")
    print(f"generated {count} chains (seed {seed}) in {out}")


def report(out):
    rows = []
    for path in sorted(out.glob("*.rs")):
        b = path.with_suffix(".base").read_text().strip() == "1"
        newp = path.with_suffix(".new")
        n = newp.read_text().strip() == "1" if newp.exists() else None
        rows.append((path, b, n))
    c = lambda f: sum(1 for r in rows if f(r))
    print(f"report: {len(rows)} chains; python refused {c(lambda r: r[1])}; syn refused {c(lambda r: r[2])}; "
          f"both {c(lambda r: r[1] and r[2])}; syn only {c(lambda r: r[2] and not r[1])}; "
          f"python only {c(lambda r: r[1] and r[2] is False)}; unjudged {c(lambda r: r[2] is None)}")
    def body(p):
        return "\n".join(p.read_text().splitlines()[3:]) + "\n"
    picks = [r for r in rows if r[1] and r[2]][:5] + [r for r in rows if not r[1] and not r[2]][:3] \
        + [r for r in rows if r[2] and not r[1]][:4]
    for p, b, n in picks:
        print(f"SAMPLE {p.stem} python={int(b)} syn={int(bool(n))}")
        print(body(p), end="")
        print("END SAMPLE")


if __name__ == "__main__":
    {"gen": gen, "report": report}[sys.argv[1]](pathlib.Path(sys.argv[2]))
