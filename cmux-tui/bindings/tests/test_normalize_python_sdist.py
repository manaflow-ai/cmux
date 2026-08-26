from __future__ import annotations

import gzip
import importlib.util
import io
import tarfile
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "normalize_python_sdist.py"
SPEC = importlib.util.spec_from_file_location("normalize_python_sdist", SCRIPT)
assert SPEC is not None
assert SPEC.loader is not None
normalizer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(normalizer)


class NormalizePythonSdistTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.root = Path(self.temporary_directory.name)

    def archive(self, path: Path, *, epoch: int, reverse: bool = False) -> None:
        entries = [
            ("cmux_sdk-1.0.0/cmux/a.py", b"a = 1\n"),
            ("cmux_sdk-1.0.0/cmux/b.py", b"b = 2\n"),
        ]
        if reverse:
            entries.reverse()
        with path.open("wb") as compressed:
            with gzip.GzipFile(
                filename="source-name.tar",
                mode="wb",
                fileobj=compressed,
                mtime=epoch,
            ) as gzip_file:
                with tarfile.open(fileobj=gzip_file, mode="w") as archive:
                    for index, (name, contents) in enumerate(entries):
                        member = tarfile.TarInfo(name)
                        member.size = len(contents)
                        member.mtime = epoch + index
                        member.uid = 501
                        member.gid = 20
                        member.uname = "builder"
                        member.gname = "staff"
                        archive.addfile(member, io.BytesIO(contents))

    def test_normalizes_order_headers_and_gzip_metadata(self) -> None:
        first = self.root / "first.tar.gz"
        second = self.root / "second.tar.gz"
        self.archive(first, epoch=100, reverse=False)
        self.archive(second, epoch=200, reverse=True)

        normalizer.normalize(first, 42)
        normalizer.normalize(second, 42)

        self.assertEqual(first.read_bytes(), second.read_bytes())
        with tarfile.open(first, "r:gz") as archive:
            members = archive.getmembers()
            self.assertEqual(
                [member.name for member in members],
                sorted(member.name for member in members),
            )
            for member in members:
                self.assertEqual(member.mtime, 42)
                self.assertEqual(member.uid, 0)
                self.assertEqual(member.gid, 0)
                self.assertEqual(member.uname, "")
                self.assertEqual(member.gname, "")

    def test_rejects_an_unsafe_member_name(self) -> None:
        archive_path = self.root / "unsafe.tar.gz"
        with tarfile.open(archive_path, "w:gz") as archive:
            member = tarfile.TarInfo("../outside.py")
            member.size = 1
            archive.addfile(member, io.BytesIO(b"x"))

        with self.assertRaises(normalizer.NormalizationError):
            normalizer.normalize(archive_path, 42)


if __name__ == "__main__":
    unittest.main()
