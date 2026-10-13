//! The Python interpreter's own process image, for fake acpmux daemons that
//! must run as `ACPMUX_BIN` (cx-ggai). `sys.executable` is not it on macOS:
//! the framework `python3` re-executes `Python.app/Contents/MacOS/Python`,
//! and a `--copies` venv does the same. Running the image directly does not.

use std::path::PathBuf;
use std::process::Command;

const IMAGE: &str = r#"
import os, sys
if sys.platform == "darwin":
    import ctypes
    buf = ctypes.create_string_buffer(4096)
    n = ctypes.CDLL("/usr/lib/libproc.dylib").proc_pidpath(os.getpid(), buf, 4096)
    print(os.path.realpath(buf.raw[:n].decode()))
else:
    print(os.path.realpath("/proc/self/exe"))
"#;

/// The path of the running Python's executable, symlinks resolved.
pub fn image() -> PathBuf {
    let out = Command::new("python3")
        .args(["-I", "-c", IMAGE])
        .output()
        .expect("python3");
    assert!(
        out.status.success(),
        "python3: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    PathBuf::from(String::from_utf8(out.stdout).unwrap().trim())
}
