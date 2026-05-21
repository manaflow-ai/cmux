#!/usr/bin/env python3
from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path


CLASS_RE = re.compile(
    r"(?m)^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:final\s+)?class\s+([A-Za-z_]\w*)\s*:\s*XCTestCase\b"
)
CONTAINER_RE = re.compile(
    r"(?m)^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:final\s+)?class\s+([A-Za-z_]\w*)\s*:\s*XCTestCase\b|extension\s+([A-Za-z_]\w*)\b)"
)
TEST_METHOD_RE = re.compile(r"(?m)^\s*(?:@\w+(?:\([^)]*\))?\s+)*func\s+(test[A-Za-z0-9_]*)\s*\(")


RUNTIME_WEIGHT_OVERRIDES = {
    # Method count underestimates these app-host, browser, and socket integration tests.
    "CLINotifyProcessIntegrationRegressionTests": 420,
    "CLINotifyProcessIntegrationTests": 150,
    "BrowserPanelWebViewLifecycleTests": 180,
    "BrowserPanelRemoteStoreTests": 160,
    "PanelOwnedNativeViewSessionTests": 100,
    "BrowserPanelPopupContextTests": 90,
    "BrowserFindJavaScriptTests": 90,
}

METHOD_SPLIT_METHOD_COUNT = 40
METHOD_SPLIT_WEIGHT = 80


@dataclass(frozen=True)
class TestMethod:
    name: str
    path: str


@dataclass(frozen=True)
class TestClass:
    name: str
    methods: tuple[TestMethod, ...]
    path: str

    @property
    def method_count(self) -> int:
        return len(self.methods)

    @property
    def weight(self) -> float:
        return max(self.method_count, RUNTIME_WEIGHT_OVERRIDES.get(self.name, 0), 1)


@dataclass(frozen=True)
class TestUnit:
    class_name: str
    path: str
    method_name: str | None
    method_count: int
    weight: float

    @property
    def only_testing_arg(self) -> str:
        if self.method_name:
            return f"-only-testing:cmuxTests/{self.class_name}/{self.method_name}"
        return f"-only-testing:cmuxTests/{self.class_name}"


def discover_test_classes(root: Path) -> list[TestClass]:
    test_root = root / "cmuxTests"
    class_paths: dict[str, str] = {}
    methods: dict[str, list[TestMethod]] = {}
    seen_methods: dict[str, set[str]] = {}

    for path in sorted(test_root.glob("*.swift")):
        text = path.read_text(encoding="utf-8")
        for match in CLASS_RE.finditer(text):
            name = match.group(1)
            class_paths[name] = path.relative_to(root).as_posix()
            methods.setdefault(name, [])
            seen_methods.setdefault(name, set())

    for path in sorted(test_root.glob("*.swift")):
        text = path.read_text(encoding="utf-8")
        matches = list(CONTAINER_RE.finditer(text))
        for index, match in enumerate(matches):
            name = match.group(1) or match.group(2)
            if name not in class_paths:
                continue
            start = match.end()
            end = matches[index + 1].start() if index + 1 < len(matches) else len(text)
            body = text[start:end]
            for method_match in TEST_METHOD_RE.finditer(body):
                method_name = method_match.group(1)
                if method_name in seen_methods[name]:
                    continue
                seen_methods[name].add(method_name)
                methods[name].append(
                    TestMethod(
                        name=method_name,
                        path=path.relative_to(root).as_posix(),
                    )
                )

    return [
        TestClass(name=name, methods=tuple(test_methods), path=class_paths[name])
        for name, test_methods in methods.items()
        if test_methods
    ]


def test_units(classes: list[TestClass]) -> list[TestUnit]:
    units: list[TestUnit] = []
    for test_class in classes:
        should_split = test_class.method_count >= METHOD_SPLIT_METHOD_COUNT or test_class.weight >= METHOD_SPLIT_WEIGHT
        if should_split:
            method_weight = max(1.0, test_class.weight / test_class.method_count)
            for method in test_class.methods:
                units.append(
                    TestUnit(
                        class_name=test_class.name,
                        path=method.path,
                        method_name=method.name,
                        method_count=1,
                        weight=method_weight,
                    )
                )
        else:
            units.append(
                TestUnit(
                    class_name=test_class.name,
                    path=test_class.path,
                    method_name=None,
                    method_count=test_class.method_count,
                    weight=test_class.weight,
                )
            )
    return units


def split_shards(units: list[TestUnit], shard_total: int) -> list[list[TestUnit]]:
    shards: list[list[TestUnit]] = [[] for _ in range(shard_total)]
    weights = [0.0] * shard_total
    for test_unit in sorted(
        units,
        key=lambda item: (-item.weight, item.path, item.class_name, item.method_name or ""),
    ):
        shard_index = min(range(shard_total), key=lambda index: (weights[index], index))
        shards[shard_index].append(test_unit)
        weights[shard_index] += test_unit.weight
    for shard in shards:
        shard.sort(key=lambda item: (item.path, item.class_name, item.method_name or ""))
    return shards


def main() -> int:
    parser = argparse.ArgumentParser(description="Print xcodebuild -only-testing args for a cmuxTests shard.")
    parser.add_argument("--root", default=".", help="Repository root. Defaults to the current directory.")
    parser.add_argument("--shard-index", type=int, required=True, help="1-based shard index.")
    parser.add_argument("--shard-total", type=int, required=True, help="Total shard count.")
    args = parser.parse_args()

    if args.shard_total < 1:
        print("--shard-total must be at least 1", file=sys.stderr)
        return 2
    if args.shard_index < 1 or args.shard_index > args.shard_total:
        print("--shard-index must be between 1 and --shard-total", file=sys.stderr)
        return 2

    root = Path(args.root).resolve()
    classes = discover_test_classes(root)
    if not classes:
        print("No XCTestCase classes discovered under cmuxTests", file=sys.stderr)
        return 1

    units = test_units(classes)
    shards = split_shards(units, args.shard_total)
    selected = shards[args.shard_index - 1]
    if not selected:
        print(f"Shard {args.shard_index}/{args.shard_total} has no XCTest test units", file=sys.stderr)
        return 1

    method_count = sum(item.method_count for item in selected)
    class_count = len({item.class_name for item in selected})
    weight = sum(item.weight for item in selected)
    print(
        f"Selected shard {args.shard_index}/{args.shard_total}: "
        f"{class_count} XCTestCase classes, {method_count} test methods, "
        f"{len(selected)} selected units, estimated weight {weight:.1f}",
        file=sys.stderr,
    )
    for item in selected:
        print(item.only_testing_arg)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
