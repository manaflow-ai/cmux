//! Whether this machine is a cmux Cloud VM, as cmux-tui's `agent_start_host.rs` reads it: the
//! Cloud image stamp (`/etc/cmux/image-stamp`), the bake instance id
//! (`/etc/cmux/bake-instance-id`) or the VM kind record (`/etc/cmux/vm-kind`) exists, or
//! `CMUX_VM_ID` is set.
//!
//! A chat on a Cloud machine never fails over onto the local CodeRouter (`hub/turns.rs`), and a
//! sign-in failure there says only how to sign the machine in (`claude_auth.rs`): the Mac's
//! "Set up Claude Code credentials" button on the turn. Leo, 2026-10-31: "STOP USING CODEROUTER".
//!
//! Not a security boundary: anything on the VM can remove these files. It only picks which
//! fallback and which words a chat there gets.

use std::path::Path;
use std::sync::OnceLock;

/// The folder the Cloud image keeps its records in.
const CLOUD_ETC: &str = "/etc/cmux";
/// Any one of these in [`CLOUD_ETC`] marks a Cloud VM.
const MARKS: [&str; 3] = ["image-stamp", "bake-instance-id", "vm-kind"];
const VM_ID_VAR: &str = "CMUX_VM_ID";

/// This machine is a cmux Cloud VM; read once per process (a few file checks).
pub fn is_cloud_vm() -> bool {
    static CLOUD: OnceLock<bool> = OnceLock::new();
    *CLOUD.get_or_init(|| {
        let vm_id = std::env::var(VM_ID_VAR).ok();
        detect(Path::new(CLOUD_ETC), vm_id.as_deref())
    })
}

/// [`is_cloud_vm`] for records in `etc` and the value of `CMUX_VM_ID`.
pub fn detect(etc: &Path, vm_id: Option<&str>) -> bool {
    vm_id.is_some_and(|id| !id.trim().is_empty())
        || MARKS.iter().any(|mark| std::fs::symlink_metadata(etc.join(mark)).is_ok())
}

#[cfg(test)]
mod tests;
