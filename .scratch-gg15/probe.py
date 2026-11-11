import sys
from pathlib import Path
ROOT = Path.cwd()
sys.path.insert(0, str(ROOT / "scripts/ci"))
import detect_ci_change_areas as m
refs = m.load_macos_job_test_references(ROOT)
for p in ["scripts/ci/" + "owned_pool" + "_rescue.py", "scripts/" + "strip-release" + "-bundle.sh"]:
    why = []
    print(p, m.ci_helper_areas(p, ROOT, refs, base_root=ROOT, why=why), "|", "; ".join(why))
    print(" classify:", m.classify_files([p]))
