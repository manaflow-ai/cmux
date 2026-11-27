#!/usr/bin/env python3
"""Which App Review gate device legs need a Mac, decided on Linux before any is queued.

  ios_review_gate_devices.py plan --devices .github/ios-review-gate-devices.json \
      --pins scripts/ci/xcode-pins.txt --trust true --out-dir DIR
  ios_review_gate_devices.py check --plan JSON --picker cmux-next-ios/scripts/app_review_pick_simulator.py \
      --out device-plan-mismatch.json

`plan` (the gate's plan job, on Linux) reads which families the reviewer-path
image has a simulator for. While xcode-pins.txt still names the Xcode that list
was checked on, a family the image lacks is not walked: the plan writes its
`<family>.skipped.json` (with the reason) into DIR, and the matrix gets only the
families to walk. It prints GITHUB_OUTPUT lines: `families` (the matrix), `skipped`
and `devices` (the whole decision, for `check`). With an unknown pin, or --trust
false (a fork's own repository, another image), it walks every family and the
legs' picker decides, as before. Only duo may be skipped: a list that says the
image lacks iphone or ipad stops the plan, and the report requires both anyway.

`check` (every leg the plan sent to a Mac) runs the legs' own picker for every
family the plan decided, with `simctl create` answered and never run, and fails
when the image disagrees with the plan: a family the plan skipped that the image
has, or one it walks that the image lacks. The mismatch file it writes makes the
report fail. Exit 0 agrees, 1 disagrees.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import subprocess
import sys
from pathlib import Path

FAMILIES = ("iphone", "ipad", "duo")
# The report's --expect-device families: walked on every run, never skipped.
REQUIRED = ("iphone", "ipad")
NO_SIMULATOR = 3  # app_review_pick_simulator.py's exit for "no simulator for this family"


class PlanError(Exception):
    pass


def pinned_xcode(pins: str, macos: str) -> str | None:
    """The Xcode scripts/ci/xcode-pins.txt names for a macOS major."""
    for line in pins.splitlines():
        fields = line.split("#", 1)[0].split()
        if len(fields) == 2 and fields[0] == macos:
            return fields[1]
    return None


def decide(devices: dict, pins: str, trust: bool) -> dict:
    image = devices.get("image") or {}
    families = devices.get("families") or {}
    xcode = pinned_xcode(pins, str(image.get("macos", "")))
    if not trust:
        why = "this repository's macOS image is not the one the device list describes"
    elif xcode is None or xcode != str(image.get("xcode", "")):
        why = (f"xcode-pins.txt names Xcode {xcode} for macOS {image.get('macos')}, "
               f"and the device list was checked on {image.get('xcode')}")
    else:
        why = ""
    if why:
        return {"decided": False, "why": why, "walk": list(FAMILIES), "skip": {}}
    walk: list[str] = []
    skip: dict[str, str] = {}
    for family in FAMILIES:
        entry = families.get(family)
        if not isinstance(entry, dict) or not isinstance(entry.get("on_image"), bool):
            raise PlanError(f"the device list has no on_image true/false for {family}")
        if entry["on_image"]:
            walk.append(family)
        elif family in REQUIRED:
            raise PlanError(f"the device list says the image has no {family} simulator, but the report "
                            f"requires {family}: fix the image or the list, never skip it")
        else:
            reason = str(entry.get("reason") or "").strip()
            if not reason:
                raise PlanError(f"the device list skips {family} with no reason")
            skip[family] = reason
    return {"decided": True, "macos": str(image.get("macos")), "xcode": xcode, "walk": walk, "skip": skip}


def plan_main(args: argparse.Namespace) -> int:
    devices = json.loads(Path(args.devices).read_text())
    pins = Path(args.pins).read_text()
    try:
        decision = decide(devices, pins, args.trust == "true")
    except PlanError as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1
    out = Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    for family, reason in decision["skip"].items():
        marker = {"family": family, "skipped": True, "planned": True, "reason": reason}
        (out / f"{family}.skipped.json").write_text(json.dumps(marker) + "\n")
    print(f"families={json.dumps(decision['walk'])}")
    print(f"skipped={json.dumps(sorted(decision['skip']))}")
    print(f"devices={json.dumps(decision, sort_keys=True)}")
    for family in FAMILIES:
        if family in decision["skip"]:
            print(f"- {family}: not walked, no Mac taken ({decision['skip'][family]})", file=sys.stderr)
        else:
            print(f"- {family}: walked", file=sys.stderr)
    if not decision["decided"]:
        print(f"- every family walked, the legs' picker decides: {decision['why']}", file=sys.stderr)
    return 0


class _NoCreate:
    """subprocess for the picker: every simctl read runs, a `simctl create` is
    answered with a placeholder and never run."""

    CalledProcessError = subprocess.CalledProcessError

    def check_output(self, cmd, *args, **kwargs):
        if list(cmd[:3]) == ["xcrun", "simctl", "create"]:
            return "probe-not-created\n"
        return subprocess.check_output(cmd, *args, **kwargs)


def load_picker(path: Path):
    spec = importlib.util.spec_from_file_location("app_review_pick_simulator", path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader
    spec.loader.exec_module(module)
    module.subprocess = _NoCreate()
    return module


def on_image(picker, family: str) -> bool:
    """The legs' own pick, with nothing created: True when it would find or
    create a simulator, False on its no-simulator exit."""
    try:
        picker.pick(family)
    except SystemExit as exit:
        if exit.code == NO_SIMULATOR:
            return False
        raise
    return True


def check_main(args: argparse.Namespace) -> int:
    decision = json.loads(args.plan)
    if not decision.get("decided"):
        print("the plan walked every family; nothing to check")
        return 0
    picker = load_picker(Path(args.picker))
    mismatches = []
    for family in FAMILIES:
        planned = family in decision.get("walk", [])
        if not planned and family not in decision.get("skip", {}):
            continue
        try:
            found = on_image(picker, family)
        except (Exception, SystemExit) as error:  # a check that could not look is never agreement
            mismatches.append({"family": family, "plan_on_image": planned, "image_on_image": None,
                               "message": f"the {family} check could not read this image's simulators: {error!r}"})
            continue
        if found != planned:
            said = "walks it" if planned else f"skipped it ({decision['skip'][family]})"
            mismatches.append({
                "family": family, "plan_on_image": planned, "image_on_image": found,
                "message": (f"the image {'has a' if found else 'has no'} {family} simulator, but the plan {said}: "
                            f"update .github/ios-review-gate-devices.json (checked on Xcode {decision.get('xcode')})"),
            })
    for item in mismatches:
        print(f"::error::{item['message']}", file=sys.stderr)
    if mismatches:
        Path(args.out).write_text(json.dumps({"mismatches": mismatches}, indent=2) + "\n")
        return 1
    print("the image agrees with the plan: " + ", ".join(
        f"{f} {'walked' if f in decision.get('walk', []) else 'absent'}" for f in FAMILIES))
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    sub = parser.add_subparsers(dest="command", required=True)
    plan = sub.add_parser("plan")
    plan.add_argument("--devices", required=True)
    plan.add_argument("--pins", required=True)
    plan.add_argument("--trust", choices=("true", "false"), required=True)
    plan.add_argument("--out-dir", required=True)
    check = sub.add_parser("check")
    check.add_argument("--plan", required=True, help="the plan job's `devices` output")
    check.add_argument("--picker", required=True)
    check.add_argument("--out", required=True)
    args = parser.parse_args(argv)
    if args.command == "plan":
        return plan_main(args)
    try:
        return check_main(args)
    except Exception as error:  # an unreadable plan or picker is never agreement
        message = f"the device check could not run: {error!r}"
        print(f"::error::{message}", file=sys.stderr)
        Path(args.out).write_text(json.dumps({"mismatches": [{"family": "", "message": message}]}, indent=2) + "\n")
        return 1


if __name__ == "__main__":
    sys.exit(main())
