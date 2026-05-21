#!/usr/bin/env python3
import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path


CLASS_RE = re.compile(
    r"(?m)^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:final\s+)?class\s+([A-Za-z_]\w*)\s*:\s*XCTestCase\b"
)
TEST_METHOD_RE = re.compile(r"(?m)^\s*(?:@\w+(?:\([^)]*\))?\s+)*func\s+test[A-Za-z0-9_]*\s*\(")


@dataclass(frozen=True)
class TestClass:
    name: str
    method_count: int
    path: str

    @property
    def weight(self) -> int:
        return max(self.method_count, 1)


def discover_test_classes(root: Path) -> list[TestClass]:
    classes: list[TestClass] = []
    for path in sorted((root / "cmuxTests").glob("*.swift")):
        text = path.read_text(encoding="utf-8")
        matches = list(CLASS_RE.finditer(text))
        for index, match in enumerate(matches):
            start = match.end()
            end = matches[index + 1].start() if index + 1 < len(matches) else len(text)
            body = text[start:end]
            method_count = len(TEST_METHOD_RE.findall(body))
            if method_count == 0:
                continue
            classes.append(
                TestClass(
                    name=match.group(1),
                    method_count=method_count,
                    path=path.relative_to(root).as_posix(),
                )
            )
    return classes


def split_shards(classes: list[TestClass], shard_total: int) -> list[list[TestClass]]:
    shards: list[list[TestClass]] = [[] for _ in range(shard_total)]
    weights = [0] * shard_total
    for test_class in sorted(classes, key=lambda item: (-item.weight, item.path, item.name)):
        shard_index = min(range(shard_total), key=lambda index: (weights[index], index))
        shards[shard_index].append(test_class)
        weights[shard_index] += test_class.weight
    for shard in shards:
        shard.sort(key=lambda item: (item.path, item.name))
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

    shards = split_shards(classes, args.shard_total)
    selected = shards[args.shard_index - 1]
    if not selected:
        print(f"Shard {args.shard_index}/{args.shard_total} has no XCTestCase classes", file=sys.stderr)
        return 1

    method_count = sum(item.method_count for item in selected)
    print(
        f"Selected shard {args.shard_index}/{args.shard_total}: "
        f"{len(selected)} XCTestCase classes, {method_count} test methods",
        file=sys.stderr,
    )
    for item in selected:
        print(f"-only-testing:cmuxTests/{item.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
