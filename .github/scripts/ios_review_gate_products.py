#!/usr/bin/env python3
"""Use fleet UI products only with the identical simulator XCTest runtime.

The Linux producer copies these binaries from its Xcode platform, but does not
stamp the Xcode distribution's build number. SDK versions and XCTRunner's own
DTXcodeBuild cannot establish compatibility. Compare the copied runtime itself;
unknown or different products must use the review worker's build-for-testing.
"""

from __future__ import annotations

import argparse
import filecmp
from pathlib import Path


FRAMEWORKS = (
    "XCTest", "XCUIAutomation", "XCTAutomationSupport", "XCTestCore",
    "XCTestSupport", "XCUnit", "Testing",
)
REQUIRED = {"XCTest.framework", "XCTestCore.framework", "libXCTestSwiftSupport.dylib"}


def framework_binary(bundle: Path) -> Path:
    # Flat iOS frameworks and versioned frameworks with the usual top-level
    # binary symlink both resolve here; Current also covers unflattened bundles.
    binary = bundle / bundle.stem
    if binary.is_file():
        return binary
    return bundle / "Versions" / "Current" / bundle.stem


def compatible(products: Path, developer: Path) -> tuple[bool, str]:
    try:
        return compare_runtime(products, developer)
    except OSError as error:
        return False, f"cannot compare XCTest runtime: {error}"


def compare_runtime(products: Path, developer: Path) -> tuple[bool, str]:
    platform = developer / "Platforms/iPhoneSimulator.platform/Developer"
    runtime = {}
    for name in FRAMEWORKS:
        for directory in ("Library/Frameworks", "Library/PrivateFrameworks"):
            bundle = platform / directory / f"{name}.framework"
            if bundle.is_dir():
                runtime[bundle.name] = framework_binary(bundle)
                break
    for pattern in ("libXCTest*.dylib", "libXCUI*.dylib"):
        for binary in (platform / "usr/lib").glob(pattern):
            runtime[binary.name] = binary
    if not REQUIRED.issubset(runtime):
        return False, "selected Xcode has no complete XCTest runtime to compare"

    runners = sorted(products.glob("**/*-Runner.app"))
    if not runners:
        return False, "products contain no UI test runner"
    for runner in runners:
        embedded = runner / "Frameworks"
        binaries = {bundle.name: framework_binary(bundle) for bundle in embedded.glob("*.framework")
                    if bundle.stem in FRAMEWORKS}
        for pattern in ("libXCTest*.dylib", "libXCUI*.dylib"):
            binaries.update((binary.name, binary) for binary in embedded.glob(pattern))
        if binaries.keys() != runtime.keys():
            return False, f"{runner.name}: XCTest runtime component set differs"
        for name, produced in sorted(binaries.items()):
            if not produced.is_file() or not runtime[name].is_file():
                return False, f"{runner.name}: missing runtime binary {name}"
            if not filecmp.cmp(produced, runtime[name], shallow=False):
                return False, f"{runner.name}: runtime binary differs: {name}"
    return True, "every UI test runner has the selected Xcode's identical XCTest runtime"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--products", required=True, type=Path)
    parser.add_argument("--developer", required=True, type=Path)
    args = parser.parse_args()
    matched, reason = compatible(args.products, args.developer)
    print(reason)
    return 0 if matched else 1


if __name__ == "__main__":
    raise SystemExit(main())
