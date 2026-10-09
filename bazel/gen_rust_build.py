#!/usr/bin/env python3
"""Generate BUILD.bazel files for cmux-tui workspace crates (Bazel pilot).

Input: `cargo metadata --format-version 1 --locked` JSON for cmux-tui/.
Usage: gen_rust_build.py METADATA_JSON REPO_ROOT ROOT_CRATE [ROOT_CRATE...]

Emits one BUILD.bazel per first-party crate in the dependency closure of the
given roots, plus //:BUILD.bazel exports for files that crates include from
outside their own directory. Third-party deps come from crate_universe's
`all_crate_deps()`/`aliases()`; first-party path deps become explicit labels.

Pilot limits (recorded in RESULT.md): first-party target-cfg path deps are
evaluated for x86_64 Linux only, and lib + unit-test + integration-test
targets get the workspace-unified feature set from `cargo metadata`.
"""
import json
import os
import re
import sys

INCLUDE_RE = re.compile(r'include_(?:str|bytes)!\(\s*"([^"]+)"\s*\)')
# include_str!(concat!("../dir/", $x, ...)): include every file under the prefix dir.
# include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/../x.json")): crate-relative.
INCLUDE_MANIFEST_RE = re.compile(r'include_(?:str|bytes)!\(\s*concat!\(\s*env!\(\s*"CARGO_MANIFEST_DIR"\s*\)\s*,\s*"([^"]+)"\s*\)')
INCLUDE_CONCAT_RE = re.compile(r'include_(?:str|bytes)!\(\s*concat!\(\s*"([^"]+)"')

# First-party build scripts replaced by Bazel attributes. Values are
# rustc_env entries; the build identity is a fixed pilot stamp (a real port
# would use --workspace_status_command + stamping).
STAMP = os.environ.get("PILOT_STAMP", "bazel-pilot")
REPLACED_BUILD_SCRIPTS = {
    "cmux-remote": {"CMUX_TUI_BUILD_IDENTITY": STAMP},
    "acpmux": {"ACPMUX_BUILD": STAMP + " 1970-01-01"},
    "cmux-tui-source-watch": {},
}
# Build scripts kept as cargo_build_script (they do real work).
KEPT_BUILD_SCRIPTS = {"ghostty-vt-sys"}


def cfg_on_linux(target):
    """Very small cfg evaluator for x86_64-unknown-linux-gnu."""
    if target is None:
        return True
    t = target.strip()
    if not t.startswith("cfg("):
        return t == "x86_64-unknown-linux-gnu"
    expr = t[4:-1]

    def ev(e):
        e = e.strip()
        if e.startswith("not("):
            return not ev(e[4:-1])
        for op in ("all(", "any("):
            if e.startswith(op):
                parts, depth, cur = [], 0, ""
                for ch in e[4:-1]:
                    if ch == "(":
                        depth += 1
                    if ch == ")":
                        depth -= 1
                    if ch == "," and depth == 0:
                        parts.append(cur)
                        cur = ""
                    else:
                        cur += ch
                if cur.strip():
                    parts.append(cur)
                vals = [ev(p) for p in parts]
                return all(vals) if op == "all(" else any(vals)
        truths = {
            "unix": True, "windows": False, "test": False, "debug_assertions": True,
            'target_os = "linux"': True, 'target_family = "unix"': True,
            'target_arch = "x86_64"': True, 'target_env = "gnu"': True,
            'target_pointer_width = "64"': True,
        }
        if e in truths:
            return truths[e]
        if e.startswith("target_") or e.startswith("feature"):
            return False
        return False

    return ev(expr)


def main():
    meta_path, repo_root = sys.argv[1], os.path.abspath(sys.argv[2])
    roots = sys.argv[3:]
    m = json.load(open(meta_path))
    ws = set(m["workspace_members"])
    pk = {p["id"]: p for p in m["packages"]}
    nodes = {n["id"]: n for n in m["resolve"]["nodes"]}
    name2id = {pk[i]["name"]: i for i in ws}

    def pkg_dir(pid):
        return os.path.relpath(os.path.dirname(pk[pid]["manifest_path"]), repo_root)

    # Closure over first-party crates, including dev-deps of the roots and
    # their first-party deps (so tests build).
    closure, stack = set(), [name2id[r] for r in roots]
    while stack:
        x = stack.pop()
        if x in closure:
            continue
        closure.add(x)
        for d in nodes[x]["deps"]:
            if d["pkg"] in ws:
                stack.append(d["pkg"])
    gen_dirs = {pkg_dir(i) for i in closure}
    # crate_universe takes each manifest's directory from its label package,
    # so every local Cargo.toml gets its own (possibly stub) Bazel package.
    stub_dirs = {pkg_dir(p["id"]) for p in m["packages"] if p["source"] is None} - gen_dirs
    pkg_dirs = gen_dirs | stub_dirs

    def label_for_file(abs_path):
        rel = os.path.relpath(abs_path, repo_root)
        d = os.path.dirname(rel)
        while d and d not in pkg_dirs:
            d = os.path.dirname(d)
        return d, os.path.relpath(rel, d) if d else rel

    root_exports = set()
    pkg_exports = {}

    def lib_target(p):
        for t in p["targets"]:
            if any(k in ("lib", "rlib", "proc-macro") for k in t["kind"]):
                return t
        return None

    def ws_label(dep_id):
        p = pk[dep_id]
        t = lib_target(p)
        return "//%s:%s" % (pkg_dir(dep_id), t["name"].replace("-", "_"))

    outputs = {}
    for pid in sorted(closure, key=lambda i: pk[i]["name"]):
        p = pk[pid]
        name = p["name"]
        pdir = pkg_dir(pid)
        absdir = os.path.join(repo_root, pdir)
        node = nodes[pid]
        features = sorted(node["features"])
        edition = p["edition"]
        version = p["version"]

        # Scan for include_str!/include_bytes! leaving the package.
        ext = set()
        for dp, dns, fns in os.walk(absdir):
            dns[:] = [x for x in dns if x != "target"]
            rel_dp = os.path.relpath(dp, repo_root)
            if rel_dp != pdir and rel_dp in pkg_dirs:
                dns[:] = []
                continue
            for fn in fns:
                if not fn.endswith(".rs"):
                    continue
                src = open(os.path.join(dp, fn), errors="replace").read()
                found = []
                for inc in INCLUDE_RE.findall(src):
                    found.append(os.path.normpath(os.path.join(dp, inc)))
                for inc in INCLUDE_MANIFEST_RE.findall(src):
                    found.append(os.path.normpath(absdir + "/" + inc.lstrip("/")))
                for inc in INCLUDE_CONCAT_RE.findall(src):
                    base = os.path.normpath(os.path.join(dp, inc))
                    base = base if os.path.isdir(base) else os.path.dirname(base)
                    for bdp, _, bfns in os.walk(base):
                        found += [os.path.join(bdp, x) for x in bfns]
                for target in found:
                    if os.path.commonpath([target, absdir]) == absdir:
                        continue
                    if not os.path.exists(target):
                        continue
                    d, relf = label_for_file(target)
                    if d == "":
                        root_exports.add(relf)
                        ext.add("//:%s" % relf)
                    else:
                        pkg_exports.setdefault(d, set()).add(relf)
                        ext.add("//%s:%s" % (d, relf))

        # First-party deps by kind.
        normal, dev, build = [], [], []
        normal_pm, dev_pm = [], []
        aliases_normal, aliases_dev = {}, {}
        dep_meta = {}
        for d in p["dependencies"]:
            dep_meta.setdefault(d["name"], []).append(d)
        for d in node["deps"]:
            if d["pkg"] not in ws:
                continue
            dp_ = pk[d["pkg"]]
            lt = lib_target(dp_)
            if lt is None:
                continue
            is_pm = "proc-macro" in lt["kind"]
            lbl = ws_label(d["pkg"])
            crate_ident = lt["name"].replace("-", "_")
            for k in d["dep_kinds"]:
                if not cfg_on_linux(k.get("target")):
                    continue
                kind = k["kind"]
                if kind is None:
                    (normal_pm if is_pm else normal).append(lbl)
                    if d["name"] != crate_ident:
                        aliases_normal[lbl] = d["name"]
                elif kind == "dev":
                    (dev_pm if is_pm else dev).append(lbl)
                    if d["name"] != crate_ident:
                        aliases_dev[lbl] = d["name"]
                elif kind == "build":
                    build.append(lbl)

        def uniq(xs):
            return sorted(set(xs))

        normal, dev, build = uniq(normal), uniq(dev), uniq(build)
        normal_pm, dev_pm = uniq(normal_pm), uniq(dev_pm)
        dev = [x for x in dev if x not in normal]
        dev_pm = [x for x in dev_pm if x not in normal_pm]

        rustc_env = dict(REPLACED_BUILD_SCRIPTS.get(name, {}))
        rustc_env.setdefault("CARGO", "cargo")
        has_build = any("custom-build" in t["kind"] for t in p["targets"])
        keep_build = has_build and name in KEPT_BUILD_SCRIPTS
        if has_build and not keep_build and name not in REPLACED_BUILD_SCRIPTS:
            raise SystemExit("unhandled first-party build script: " + name)

        lines = [
            "# Generated by bazel/gen_rust_build.py (Bazel pilot). Do not edit.",
            'load("@crates//:defs.bzl", "aliases", "all_crate_deps")',
            'load("@rules_rust//rust:defs.bzl", "rust_binary", "rust_library", "rust_proc_macro", "rust_test")',
        ]
        if keep_build:
            lines.append('load("@rules_rust//cargo:defs.bzl", "cargo_build_script")')
        lines += [
            "",
            'package(default_visibility = ["//visibility:public"])',
            "",
        ]
        lines.append("@EXPORTS@")
        lines += [
            "SRCS = glob([\"**/*.rs\"], exclude = [\"target/**\"])",
            "",
            "DATA = glob([\"**\"], exclude = [\"**/*.rs\", \"BUILD.bazel\", \"target/**\", \"**/.*/**/*\"]) + %s"
            % json.dumps(sorted(ext)),
            "",
            "FEATURES = %s" % json.dumps(features),
            "",
            "RUSTC_ENV = %s" % json.dumps(rustc_env, sort_keys=True),
            "",
        ]
        deps_expr = "all_crate_deps(normal = True) + %s" % json.dumps(normal)
        pm_expr = "all_crate_deps(proc_macro = True) + %s" % json.dumps(normal_pm)
        if keep_build:
            deps_expr += ' + [":build_script"]'
            lines += [
                "cargo_build_script(",
                '    name = "build_script",',
                '    srcs = glob(["build.rs", "build_support.rs"]),',
                '    crate_root = "build.rs",',
                "    edition = %s," % json.dumps(edition),
                "    deps = all_crate_deps(build = True) + %s," % json.dumps(build),
                "    proc_macro_deps = all_crate_deps(build_proc_macro = True),",
                '    data = ["//:ghostty_next_srcs"],',
                '    links = "ghostty-vt",',
                "    build_script_env = {",
                '        "ZIG": "/usr/local/bin/zig",',
                '        "ZIG_GLOBAL_CACHE_DIR": "/work/bazel-pilot/zig-global",',
                '        "CMUX_GHOSTTY_SRC": "/work/bazel-pilot/src/ghostty-next",',
                "    },",
                "    # PILOT HACK: zig's installHeadersDirectory skips symlinks, so it",
                "    # cannot build from Bazel's symlinked runfiles tree. The script",
                "    # builds in the real checkout (as cargo does), writing .zig-cache",
                "    # and zig-pkg there and fetching packages: no sandbox, network on.",
                "    # Inputs stay declared via data, so cache keys remain correct.",
                '    tags = ["no-sandbox", "requires-network"],',
                ")",
                "",
            ]

        lt = lib_target(p)
        if lt is not None:
            is_pm = "proc-macro" in lt["kind"]
            rule = "rust_proc_macro" if is_pm else "rust_library"
            lib_name = lt["name"].replace("-", "_")
            crate_root = os.path.relpath(lt["src_path"], absdir)
            lines += [
                "%s(" % rule,
                "    name = %s," % json.dumps(lib_name),
                "    srcs = SRCS,",
                "    crate_root = %s," % json.dumps(crate_root),
                "    compile_data = DATA,",
                "    crate_features = FEATURES,",
                "    edition = %s," % json.dumps(edition),
                "    version = %s," % json.dumps(version),
                "    rustc_env = RUSTC_ENV,",
                "    aliases = aliases() | %s," % json.dumps(aliases_normal),
                "    deps = %s," % deps_expr,
                "    proc_macro_deps = %s," % pm_expr,
                ")",
                "",
                "rust_test(",
                "    name = %s," % json.dumps(lib_name + "_unit_test"),
                "    crate = %s," % json.dumps(":" + lib_name),
                "    compile_data = DATA,",
                "    data = DATA,",
                "    rustc_env = RUSTC_ENV,",
                "    aliases = aliases(normal_dev = True) | %s," % json.dumps(aliases_dev),
                "    deps = all_crate_deps(normal_dev = True) + %s," % json.dumps(dev),
                "    proc_macro_deps = all_crate_deps(proc_macro_dev = True) + %s," % json.dumps(dev_pm),
                ")",
                "",
            ]
        for t in p["targets"]:
            kind = t["kind"]
            root = os.path.relpath(t["src_path"], absdir)
            tname = t["name"].replace("-", "_")
            base = [
                "    srcs = SRCS,",
                "    crate_root = %s," % json.dumps(root),
                "    compile_data = DATA,",
                "    crate_features = FEATURES,",
                "    edition = %s," % json.dumps(edition),
                "    version = %s," % json.dumps(version),
                "    rustc_env = RUSTC_ENV,",
            ]
            own = [":" + lt["name"].replace("-", "_")] if lt is not None else []
            if "bin" in kind:
                lines += ["rust_binary(", "    name = %s," % json.dumps(tname + "_bin"),
                          "    crate_name = %s," % json.dumps(tname)] + base + [
                    "    aliases = aliases() | %s," % json.dumps(aliases_normal),
                    "    deps = %s + %s," % (deps_expr, json.dumps(own)),
                    "    proc_macro_deps = %s," % pm_expr,
                    ")", ""]
            elif "test" in kind:
                # Cargo sets CARGO_BIN_EXE_<bin> and CARGO_TARGET_TMPDIR for
                # integration tests; rules_rust does not, so map them here.
                bins = [b["name"] for b in p["targets"] if "bin" in b["kind"]]
                env = dict(rustc_env)
                env["CARGO_TARGET_TMPDIR"] = "/tmp/bazel-pilot-target-tmp"
                for b in bins:
                    env["CARGO_BIN_EXE_" + b] = "$(rootpath :%s_bin)" % b.replace("-", "_")
                base = [x if not x.startswith("    rustc_env") else "    rustc_env = %s," % json.dumps(env, sort_keys=True) for x in base]
                lines += ["rust_test(", "    name = %s," % json.dumps("it_" + tname),
                          "    crate_name = %s," % json.dumps(tname)] + base + [
                    "    data = DATA + %s," % json.dumps([":%s_bin" % b.replace("-", "_") for b in bins]),
                    "    aliases = aliases(normal_dev = True) | %s | %s," % (json.dumps(aliases_normal), json.dumps(aliases_dev)),
                    "    deps = %s + all_crate_deps(normal_dev = True) + %s + %s," % (deps_expr, json.dumps(dev), json.dumps(own)),
                    "    proc_macro_deps = %s + all_crate_deps(proc_macro_dev = True) + %s," % (pm_expr, json.dumps(dev_pm)),
                    ")", ""]

        outputs[pdir] = "\n".join(lines)

    for d in stub_dirs:
        outputs[d] = "# Bazel pilot stub: crate_universe needs a package per Cargo.toml.\n@EXPORTS@\n"
    for pdir, text in outputs.items():
        exports = pkg_exports.get(pdir)
        text = text.replace("@EXPORTS@\n", "exports_files(%s)\n\n" % json.dumps(sorted(exports), indent=4) if exports else "")
        with open(os.path.join(repo_root, pdir, "BUILD.bazel"), "w") as f:
            f.write(text)
        print("wrote", os.path.join(pdir, "BUILD.bazel"))

    with open(os.path.join(repo_root, "bazel", "root_exports.json"), "w") as f:
        json.dump(sorted(root_exports), f, indent=2)
    print("root exports:", len(root_exports))


if __name__ == "__main__":
    main()
