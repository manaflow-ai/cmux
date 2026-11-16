#!/usr/bin/env python3
"""Pick (or create) the simulator for one App Review gate device family.

  iphone  the largest current iPhone (a Pro Max is regular width in
          landscape, so rotation exercises the compact/regular change)
  ipad    a 13-inch iPad, the device App Review used for the 2026-11-07 run
  duo     iPhone Duo, the foldable, when the image has a runtime for it

Exit 3 when the family has no device type or runtime on this machine.

  app_review_pick_simulator.py --family ipad --print-udid
  app_review_pick_simulator.py --family iphone --print-destination
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys

PREFERRED = {
    "iphone": ["iPhone 17 Pro Max", "iPhone 16 Pro Max", "iPhone 17 Pro", "iPhone 17", "iPhone 16"],
    "ipad": ["iPad Pro 13-inch (M5)", "iPad Pro 13-inch (M4)", "iPad Air 13-inch (M3)"],
    "duo": ["iPhone Duo"],
}


def simctl(*args: str) -> dict:
    return json.loads(subprocess.check_output(["xcrun", "simctl", "list", *args, "-j"], text=True))


def version(runtime: dict) -> tuple[int, ...]:
    return tuple(int(x) for x in str(runtime.get("version", "0")).split(".") if x.isdigit())


def pick(family: str) -> str:
    names = PREFERRED[family]
    runtimes = [
        r for r in simctl("runtimes")["runtimes"]
        if r.get("isAvailable", True) and r.get("platform", "iOS") == "iOS"
    ]
    devices = simctl("devices", "available")["devices"]
    for name in names:
        for runtime in sorted(runtimes, key=version, reverse=True):
            for device in devices.get(runtime["identifier"], []):
                if device.get("name") == name and device.get("isAvailable", True):
                    return device["udid"]
    device_types = {d["name"]: d for d in simctl("devicetypes")["devicetypes"]}
    for name in names:
        dtype = device_types.get(name)
        if not dtype:
            continue
        for runtime in sorted(runtimes, key=version, reverse=True):
            supported = {d["identifier"] for d in runtime.get("supportedDeviceTypes", [])}
            if supported and dtype["identifier"] not in supported:
                continue
            created = f"cmux review gate {os.environ.get('GITHUB_RUN_ID', 'local')} {name}"
            return subprocess.check_output(
                ["xcrun", "simctl", "create", created, dtype["identifier"], runtime["identifier"]], text=True
            ).strip()
    raise SystemExit(3)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--family", choices=sorted(PREFERRED), required=True)
    out = parser.add_mutually_exclusive_group(required=True)
    out.add_argument("--print-udid", action="store_true")
    out.add_argument("--print-destination", action="store_true")
    args = parser.parse_args()
    udid = pick(args.family)
    print(udid if args.print_udid else f"platform=iOS Simulator,id={udid}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
